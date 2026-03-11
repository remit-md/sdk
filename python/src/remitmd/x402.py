"""x402 client middleware for auto-paying HTTP 402 Payment Required responses.

x402 is an open payment standard where resource servers return HTTP 402 with
a ``PAYMENT-REQUIRED`` header describing the cost. This module provides an
httpx wrapper that intercepts those responses, signs an EIP-3009 authorization,
and retries the request with a ``PAYMENT-SIGNATURE`` header.

Usage::

    from remitmd import Wallet, PrivateKeySigner
    from remitmd.x402 import X402Client

    signer = PrivateKeySigner("0x...")
    wallet = Wallet(signer=signer, chain="base-sepolia", testnet=True)
    client = X402Client(wallet=wallet, max_auto_pay_usdc=0.10)

    async with client:
        response = await client.get("https://api.provider.com/v1/data")
"""

from __future__ import annotations

import base64
import json
import secrets
import time
from typing import Any

import httpx

from remitmd.signer import Signer

# EIP-712 type definition for USDC's transferWithAuthorization (EIP-3009).
# Domain: { name: "USD Coin", version: "2", chainId: N, verifyingContract: USDC }
_EIP3009_TYPES: dict[str, list[dict[str, str]]] = {
    "TransferWithAuthorization": [
        {"name": "from", "type": "address"},
        {"name": "to", "type": "address"},
        {"name": "value", "type": "uint256"},
        {"name": "validAfter", "type": "uint256"},
        {"name": "validBefore", "type": "uint256"},
        {"name": "nonce", "type": "bytes32"},
    ]
}


class AllowanceExceededError(Exception):
    """Raised when an x402 payment exceeds the configured auto-pay limit."""

    def __init__(self, amount_usdc: float, limit_usdc: float) -> None:
        super().__init__(
            f"x402 payment {amount_usdc:.6f} USDC exceeds auto-pay limit {limit_usdc:.6f} USDC"
        )
        self.amount_usdc = amount_usdc
        self.limit_usdc = limit_usdc


class X402Client:
    """
    httpx wrapper that auto-handles HTTP 402 Payment Required responses.

    On receiving a 402, the client:

    1. Decodes the ``PAYMENT-REQUIRED`` header (base64 JSON)
    2. Checks the amount is within ``max_auto_pay_usdc``
    3. Builds and signs an EIP-3009 ``transferWithAuthorization``
    4. Base64-encodes the ``PAYMENT-SIGNATURE`` header
    5. Retries the original request with payment attached

    Args:
        wallet: remit.md ``Wallet`` (provides address and signing capability).
        max_auto_pay_usdc: Maximum USDC amount to auto-pay per request.
        timeout: HTTP timeout in seconds.
    """

    def __init__(
        self,
        wallet: Any,  # remitmd.wallet.Wallet — avoid circular import
        max_auto_pay_usdc: float = 0.10,
        timeout: float = 30.0,
    ) -> None:
        self._signer: Signer = wallet._signer
        self._address: str = wallet.address
        self._max_auto_pay_usdc = max_auto_pay_usdc
        self._http = httpx.AsyncClient(timeout=timeout)

    # ─── Public request methods ────────────────────────────────────────────────

    async def get(self, url: str, **kwargs: Any) -> httpx.Response:
        """GET request with automatic x402 payment handling."""
        return await self.request("GET", url, **kwargs)

    async def post(self, url: str, **kwargs: Any) -> httpx.Response:
        """POST request with automatic x402 payment handling."""
        return await self.request("POST", url, **kwargs)

    async def request(self, method: str, url: str, **kwargs: Any) -> httpx.Response:
        """Generic request with automatic x402 payment handling."""
        response = await self._http.request(method, url, **kwargs)
        if response.status_code == 402:
            response = await self._handle_402(method, url, response, **kwargs)
        return response

    # ─── 402 handling ─────────────────────────────────────────────────────────

    async def _handle_402(
        self,
        method: str,
        url: str,
        response: httpx.Response,
        **kwargs: Any,
    ) -> httpx.Response:
        # 1. Decode PAYMENT-REQUIRED header (httpx normalises header names to lowercase).
        raw = response.headers.get("payment-required")
        if not raw:
            raise ValueError("402 response missing PAYMENT-REQUIRED header")

        required: dict[str, Any] = json.loads(base64.b64decode(raw))

        # 2. Only the "exact" scheme is supported in V5.
        if required.get("scheme") != "exact":
            raise ValueError(f"Unsupported x402 scheme: {required.get('scheme')!r}")

        # 3. Check auto-pay limit.
        amount_base_units = int(required["amount"])
        amount_usdc = amount_base_units / 1_000_000
        if amount_usdc > self._max_auto_pay_usdc:
            raise AllowanceExceededError(amount_usdc, self._max_auto_pay_usdc)

        # 4. Parse chainId from CAIP-2 network string (e.g. "eip155:84532" → 84532).
        network: str = required["network"]
        chain_id = int(network.split(":")[1])

        # 5. Build EIP-3009 authorization fields.
        now = int(time.time())
        valid_before = now + int(required.get("maxTimeoutSeconds", 60))
        nonce = "0x" + secrets.token_hex(32)

        domain: dict[str, Any] = {
            "name": "USD Coin",
            "version": "2",
            "chainId": chain_id,
            "verifyingContract": required["asset"],
        }
        # eth_account encodes uint256 from Python int and bytes32 from 0x-hex string.
        eip712_value: dict[str, Any] = {
            "from": self._address,
            "to": required["payTo"],
            "value": amount_base_units,
            "validAfter": 0,
            "validBefore": valid_before,
            "nonce": nonce,
        }

        # 6. Sign with EIP-712.
        signature = await self._signer.sign_typed_data(domain, _EIP3009_TYPES, eip712_value)

        # 7. Build PAYMENT-SIGNATURE JSON payload.
        payment_payload = {
            "scheme": required["scheme"],
            "network": network,
            "x402Version": 1,
            "payload": {
                "signature": signature,
                "authorization": {
                    "from": self._address,
                    "to": required["payTo"],
                    "value": required["amount"],  # string (base units)
                    "validAfter": "0",
                    "validBefore": str(valid_before),
                    "nonce": nonce,
                },
            },
        }
        payment_header = base64.b64encode(json.dumps(payment_payload).encode()).decode()

        # 8. Retry with PAYMENT-SIGNATURE header.
        headers: dict[str, str] = dict(kwargs.pop("headers", {}))
        headers["PAYMENT-SIGNATURE"] = payment_header
        return await self._http.request(method, url, headers=headers, **kwargs)

    # ─── Context manager ───────────────────────────────────────────────────────

    async def close(self) -> None:
        await self._http.aclose()

    async def __aenter__(self) -> X402Client:
        return self

    async def __aexit__(self, *_: Any) -> None:
        await self.close()

    def __repr__(self) -> str:
        return (
            f"X402Client(address={self._address!r}, max_auto_pay_usdc={self._max_auto_pay_usdc!r})"
        )
