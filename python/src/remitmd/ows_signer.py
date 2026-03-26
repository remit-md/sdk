"""OWS (Open Wallet Standard) signer adapter.

Wraps the ``open-wallet-standard`` FFI module to implement the Remit
Signer interface.  OWS handles encrypted key storage + policy-gated signing;
this adapter translates between Remit's (domain, types, value) EIP-712
calling convention and OWS's JSON string convention.

Usage::

    signer = OwsSigner(wallet_id="remit-my-agent")
    wallet = Wallet(signer=signer, chain="base")
"""

from __future__ import annotations

import json
from typing import Any

from remitmd.signer import Signer


class OwsSigner(Signer):
    """Signer backed by the Open Wallet Standard.

    Keys live in OWS's encrypted vault (``~/.ows/wallets/``), never in env vars.
    Signing calls go through OWS FFI, which evaluates policy rules before signing.

    The constructor resolves the wallet address synchronously via ``ows.get_wallet()``.
    If ``open-wallet-standard`` is not installed, a clear error is raised.
    """

    def __init__(
        self,
        wallet_id: str,
        chain: str = "base",
        ows_api_key: str | None = None,
        *,
        _ows_module: Any = None,
    ) -> None:
        if _ows_module is not None:
            self._ows = _ows_module
        else:
            try:
                import ows  # type: ignore[import-untyped]

                self._ows = ows
            except ImportError:
                raise ImportError(
                    "OWS_WALLET_ID is set but open-wallet-standard is not installed. "
                    "Install it with: pip install open-wallet-standard"
                ) from None

        self._wallet_id = wallet_id
        self._chain = chain
        self._ows_api_key = ows_api_key

        # Resolve address at construction time (sync FFI call).
        wallet_info = self._ows.get_wallet(wallet_id)
        accounts: list[dict[str, str]] = wallet_info.get("accounts", [])
        evm_account = next(
            (
                a
                for a in accounts
                if a.get("chain_id") == "evm" or a.get("chain_id", "").startswith("eip155:")
            ),
            None,
        )
        if evm_account is None:
            chains = ", ".join(a.get("chain_id", "?") for a in accounts) or "none"
            raise ValueError(
                f"No EVM account found in OWS wallet '{wallet_id}'. Available chains: {chains}."
            )
        self._address: str = evm_account["address"]

    def get_address(self) -> str:
        return self._address

    async def sign_typed_data(
        self,
        domain: dict[str, object],
        types: dict[str, object],
        value: dict[str, object],
    ) -> str:
        # 1. Derive primaryType: first key in types that is NOT "EIP712Domain".
        primary_type = next(
            (k for k in types if k != "EIP712Domain"),
            "Request",
        )

        # 2. Build EIP712Domain type array dynamically from domain fields (G3).
        eip712_domain_type: list[dict[str, str]] = []
        if "name" in domain:
            eip712_domain_type.append({"name": "name", "type": "string"})
        if "version" in domain:
            eip712_domain_type.append({"name": "version", "type": "string"})
        if "chainId" in domain:
            eip712_domain_type.append({"name": "chainId", "type": "uint256"})
        if "verifyingContract" in domain:
            eip712_domain_type.append({"name": "verifyingContract", "type": "address"})

        # 3. Assemble full EIP-712 typed data structure.
        full_typed_data = {
            "types": {"EIP712Domain": eip712_domain_type, **types},
            "primaryType": primary_type,
            "domain": domain,
            "message": value,
        }

        # 4. Serialize to JSON.
        typed_data_json = json.dumps(full_typed_data)

        # 5. Call OWS FFI.  Chain is always "evm" for EVM signing (G2).
        #    OWS Python SDK is synchronous — no await needed.
        result: dict[str, Any] = self._ows.sign_typed_data(
            self._wallet_id,
            "evm",
            typed_data_json,
            self._ows_api_key,
        )

        # 6. Concatenate r+s+v into 65-byte Ethereum signature (S4).
        sig: str = result["signature"]
        if sig.startswith("0x"):
            sig = sig[2:]

        # G6: If OWS already returns r+s+v (130 hex chars), use as-is.
        if len(sig) == 130:
            return f"0x{sig}"

        # Otherwise it's r+s (128 hex chars), append v.
        recovery_id: int = result.get("recovery_id") or 0
        v = recovery_id + 27
        return f"0x{sig}{v:02x}"

    # Never expose key material or API keys.
    def __repr__(self) -> str:
        return f"OwsSigner(address={self._address!r}, wallet={self._wallet_id!r})"

    def __str__(self) -> str:
        return self.__repr__()
