"""Wallet — read + write client (requires a private key or custom Signer)."""

from __future__ import annotations

import os
import secrets
import time
from collections.abc import Callable
from typing import Any

from remitmd._http import AuthenticatedClient, get_chain_config
from remitmd.client import RemitClient
from remitmd.models.bounty import Bounty
from remitmd.models.common import LinkResponse, Transaction, WalletStatus, Webhook
from remitmd.models.deposit import Deposit
from remitmd.models.escrow import Escrow
from remitmd.models.invoice import Invoice
from remitmd.models.stream import Stream
from remitmd.models.tab import Tab, TabCharge
from remitmd.signer import PrivateKeySigner, Signer


class PermitSignature:
    """EIP-2612 permit signature for gasless USDC approval."""

    __slots__ = ("value", "deadline", "v", "r", "s")

    def __init__(self, value: int, deadline: int, v: int, r: str, s: str) -> None:
        self.value = value
        self.deadline = deadline
        self.v = v
        self.r = r
        self.s = s

    def to_dict(self) -> dict[str, object]:
        return {
            "value": self.value,
            "deadline": self.deadline,
            "v": self.v,
            "r": self.r,
            "s": self.s,
        }


# Default USDC contract addresses per chain.
USDC_ADDRESSES: dict[str, str] = {
    "base-sepolia": "0x2d846325766921935f37d5b4478196d3ef93707c",
    "base": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    "localhost": "0x5FbDB2315678afecb367f032d93F642f64180aa3",
}

DEFAULT_RPC_URLS: dict[str, str] = {
    "base-sepolia": "https://sepolia.base.org",
    "base": "https://mainnet.base.org",
    "localhost": "http://127.0.0.1:8545",
}


class Wallet(RemitClient):
    """
    Full remit.md wallet with signing capability.

    Usage:
        wallet = Wallet.from_env()
        tx = await wallet.pay_direct("0xRecipient...", 5.00, memo="thanks")

    Private keys are held only by the Signer object and are never exposed
    via repr, str, or any public attribute.
    """

    def __init__(
        self,
        private_key: str | None = None,
        chain: str = "base",
        testnet: bool = False,
        api_url: str | None = None,
        signer: Signer | None = None,
        router_address: str | None = None,
        rpc_url: str | None = None,
    ) -> None:
        if private_key is None and signer is None:
            private_key = os.environ.get("REMITMD_KEY")
            if not private_key:
                raise ValueError(
                    "Provide private_key, signer, or set the REMITMD_KEY environment variable"
                )
        if private_key is not None and signer is not None:
            raise ValueError("Provide private_key OR signer, not both")

        chain_id, url = get_chain_config(chain, testnet, api_url)
        self.chain = chain
        self.testnet = testnet
        self._chain_id = chain_id

        # Router contract address for EIP-712 domain — must match server's ROUTER_ADDRESS.
        verifying_contract = router_address or os.environ.get("REMITMD_ROUTER_ADDRESS", "")

        self._signer: Signer = signer if signer is not None else PrivateKeySigner(private_key)  # type: ignore[arg-type]
        self._http = AuthenticatedClient(
            url, signer=self._signer, chain_id=chain_id, verifying_contract=verifying_contract
        )
        self._contracts_cache = None

        # RPC URL for on-chain queries (nonce fetching for auto-permit).
        self._rpc_url = (
            rpc_url
            or os.environ.get("REMITMD_RPC_URL")
            or DEFAULT_RPC_URLS.get(chain, DEFAULT_RPC_URLS["base-sepolia"])
        )

        # Event callbacks: event_type → list of callables
        self._callbacks: dict[str, list[Callable[..., Any]]] = {}

    # ─── Constructors ─────────────────────────────────────────────────────────

    @classmethod
    def create(cls, chain: str = "base", testnet: bool = False) -> Wallet:
        """Generate a new random wallet (useful for testing / onboarding)."""
        key = "0x" + secrets.token_hex(32)
        return cls(private_key=key, chain=chain, testnet=testnet)

    @classmethod
    def from_env(cls, chain: str | None = None) -> Wallet:
        """Load wallet from REMITMD_KEY and REMITMD_CHAIN environment variables."""
        key = os.environ.get("REMITMD_KEY")
        if not key:
            raise OSError("REMITMD_KEY environment variable is not set")
        resolved_chain = chain or os.environ.get("REMITMD_CHAIN", "base")
        testnet = os.environ.get("REMITMD_TESTNET", "").lower() in ("1", "true", "yes")
        return cls(private_key=key, chain=resolved_chain, testnet=testnet)

    # ─── Address ──────────────────────────────────────────────────────────────

    @property
    def address(self) -> str:
        """Checksummed Ethereum address for this wallet."""
        return self._signer.get_address()

    # ─── EIP-2612 Permit ─────────────────────────────────────────────────────

    async def sign_usdc_permit(
        self,
        spender: str,
        value: int,
        deadline: int,
        nonce: int = 0,
        usdc_address: str | None = None,
    ) -> PermitSignature:
        """Sign an EIP-2612 permit for USDC approval.

        Args:
            spender: Contract address that will be approved.
            value: Amount in USDC base units (6 decimals).
            deadline: Permit deadline (Unix timestamp).
            nonce: Current permit nonce for this wallet (default: 0).
            usdc_address: Override the USDC contract address.

        Returns:
            A PermitSignature that can be passed to pay_direct(), pay(),
            open_tab(), open_stream(), post_bounty(), or place_deposit().
        """
        usdc_addr = usdc_address or USDC_ADDRESSES.get(self.chain, "")

        domain = {
            "name": "USD Coin",
            "version": "2",
            "chainId": self._chain_id,
            "verifyingContract": usdc_addr,
        }
        types: dict[str, object] = {
            "Permit": [
                {"name": "owner", "type": "address"},
                {"name": "spender", "type": "address"},
                {"name": "value", "type": "uint256"},
                {"name": "nonce", "type": "uint256"},
                {"name": "deadline", "type": "uint256"},
            ],
        }
        message = {
            "owner": self.address,
            "spender": spender,
            "value": str(value),
            "nonce": nonce,
            "deadline": deadline,
        }

        sig = await self._signer.sign_typed_data(domain, types, message)
        sig_hex = sig if sig.startswith("0x") else f"0x{sig}"
        sig_bytes = sig_hex[2:]
        r = f"0x{sig_bytes[:64]}"
        s = f"0x{sig_bytes[64:128]}"
        v = int(sig_bytes[128:130], 16)

        return PermitSignature(value=value, deadline=deadline, v=v, r=r, s=s)

    async def _fetch_usdc_nonce(self, usdc_address: str) -> int:
        """Fetch the current EIP-2612 nonce for this wallet from the USDC contract."""
        import httpx

        padded = self.address.lower().replace("0x", "").zfill(64)
        data = f"0x7ecebe00{padded}"
        payload = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_call",
            "params": [{"to": usdc_address, "data": data}, "latest"],
        }
        async with httpx.AsyncClient() as client:
            resp = await client.post(self._rpc_url, json=payload)
            result = resp.json()
        if "error" in result:
            msg = result["error"].get("message", result["error"])
            raise RuntimeError(f"RPC error fetching nonce: {msg}")
        return int(result.get("result", "0x0"), 16)

    async def sign_permit(
        self,
        spender: str,
        amount: float,
        deadline: int | None = None,
    ) -> PermitSignature:
        """Convenience: sign a USDC permit. Auto-fetches nonce, defaults deadline to 1 hour.

        Args:
            spender: Contract address to approve (e.g. router, escrow).
            amount: Amount in USDC (e.g. 5.0 for $5.00).
            deadline: Optional Unix timestamp. Defaults to 1 hour from now.
        """
        usdc_addr = USDC_ADDRESSES.get(self.chain, "")
        nonce = await self._fetch_usdc_nonce(usdc_addr)
        dl = deadline or (int(time.time()) + 3600)
        raw = int(round(amount * 1_000_000))
        return await self.sign_usdc_permit(spender, raw, dl, nonce, usdc_addr)

    async def _auto_permit(self, contract: str, amount: float) -> PermitSignature | None:
        """Internal: auto-sign a permit for the given contract type and amount.

        Catches permit-specific errors (missing contract, signing failures)
        and returns None. Re-raises all other errors.
        """
        import logging

        logger = logging.getLogger("remitmd")
        try:
            contracts = await self.get_contracts()
            spender = str(contracts.get(contract, ""))
            if not spender:
                return None
            return await self.sign_permit(spender, amount)
        except (ValueError, KeyError, TypeError, RuntimeError) as exc:
            logger.warning("auto-permit failed for %s (amount=%s): %s", contract, amount, exc)
            return None

    # ─── Direct payment ───────────────────────────────────────────────────────

    async def pay_direct(
        self,
        to: str,
        amount: float,
        memo: str = "",
        permit: PermitSignature | None = None,
    ) -> Transaction:
        """Send a direct USDC payment (no escrow, no refund)."""
        resolved = permit if permit is not None else await self._auto_permit("router", amount)
        nonce = secrets.token_hex(16)
        body: dict[str, Any] = {
            "to": to,
            "amount": amount,
            "task": memo,
            "chain": self.chain,
            "nonce": nonce,
            "signature": "0x",
        }
        if resolved is not None:
            body["permit"] = resolved.to_dict()
        data = await self._http.post("/api/v1/payments/direct", body)
        return Transaction.model_validate(data)

    # ─── Escrow ───────────────────────────────────────────────────────────────

    async def pay(
        self,
        invoice: Invoice,
        permit: PermitSignature | None = None,
    ) -> Escrow:
        """Fund an escrow: create invoice then fund escrow in one call."""
        import uuid

        invoice_id = invoice.id or str(uuid.uuid4())
        nonce = secrets.token_hex(16)

        # Step 1: create the invoice on the server.
        inv_body: dict[str, Any] = {
            "id": invoice_id,
            "chain": invoice.chain or self.chain,
            "from_agent": self.address.lower(),
            "to_agent": invoice.to.lower(),
            "amount": invoice.amount,
            "type": invoice.payment_model or "escrow",
            "task": invoice.memo,
            "nonce": nonce,
            "signature": "0x",
        }
        if invoice.timeout:
            inv_body["escrow_timeout"] = invoice.timeout
        await self._http.post("/api/v1/invoices", inv_body)

        # Step 2: fund the escrow.
        resolved = permit or await self._auto_permit("escrow", invoice.amount)
        escrow_body: dict[str, Any] = {"invoice_id": invoice_id}
        if resolved is not None:
            escrow_body["permit"] = resolved.to_dict()
        data = await self._http.post("/api/v1/escrows", escrow_body)
        return Escrow.model_validate(data)

    async def claim_start(self, invoice_id: str) -> Escrow:
        """Payee calls this to start work and begin the escrow timer."""
        data = await self._http.post(f"/api/v1/escrows/{invoice_id}/claim-start", {})
        return Escrow.model_validate(data)

    async def submit_evidence(
        self,
        invoice_id: str,
        evidence_uri: str,
        evidence_hash: str = "",
    ) -> Escrow:
        """Submit evidence for an escrow via the claim-start endpoint.

        Args:
            invoice_id: The invoice/escrow ID.
            evidence_uri: URI pointing to the evidence (e.g. IPFS hash).
            evidence_hash: Optional hash of the evidence content.
        """
        body: dict[str, Any] = {"evidence_uri": evidence_uri}
        if evidence_hash:
            body["evidence_hash"] = evidence_hash
        data = await self._http.post(
            f"/api/v1/escrows/{invoice_id}/claim-start",
            body,
        )
        return Escrow.model_validate(data)

    async def release_escrow(self, invoice_id: str) -> Escrow:
        data = await self._http.post(f"/api/v1/escrows/{invoice_id}/release", {})
        return Escrow.model_validate(data)

    async def release_milestone(self, invoice_id: str, milestone_index: int) -> Escrow:
        data = await self._http.post(
            f"/api/v1/escrows/{invoice_id}/release",
            {"milestone_ids": [str(milestone_index)]},
        )
        return Escrow.model_validate(data)

    async def cancel_escrow(self, invoice_id: str) -> Escrow:
        data = await self._http.post(f"/api/v1/escrows/{invoice_id}/cancel", {})
        return Escrow.model_validate(data)

    # ─── Metered tabs ─────────────────────────────────────────────────────────

    async def open_tab(
        self,
        to: str,
        limit: float,
        per_unit: float,
        expires: int = 86400,
        permit: PermitSignature | None = None,
    ) -> Tab:
        resolved = permit if permit is not None else await self._auto_permit("tab", limit)
        expiry = int(time.time()) + expires
        body: dict[str, Any] = {
            "chain": self.chain,
            "provider": to,
            "limit_amount": limit,
            "per_unit": per_unit,
            "expiry": expiry,
        }
        if resolved is not None:
            body["permit"] = resolved.to_dict()
        data = await self._http.post("/api/v1/tabs", body)
        return Tab.model_validate(data)

    async def charge_tab(
        self,
        tab_id: str,
        amount: float,
        cumulative: float,
        call_count: int,
        provider_sig: str,
    ) -> TabCharge:
        """Provider-side: charge a tab with an EIP-712 TabCharge signature."""
        data = await self._http.post(
            f"/api/v1/tabs/{tab_id}/charge",
            {
                "amount": amount,
                "cumulative": cumulative,
                "call_count": call_count,
                "provider_sig": provider_sig,
            },
        )
        return TabCharge.model_validate(data)

    async def close_tab(
        self,
        tab_id: str,
        final_amount: float = 0,
        provider_sig: str = "0x",
    ) -> Tab:
        data = await self._http.post(
            f"/api/v1/tabs/{tab_id}/close",
            {"final_amount": final_amount, "provider_sig": provider_sig},
        )
        return Tab.model_validate(data)

    async def sign_tab_charge(
        self,
        tab_contract: str,
        tab_id: str,
        total_charged: int,
        call_count: int,
    ) -> str:
        """Sign a TabCharge EIP-712 message (provider-side).

        Args:
            tab_contract: Tab contract address (verifyingContract for domain).
            tab_id: UUID of the tab (will be encoded as bytes32).
            total_charged: Cumulative charged amount in USDC base units (uint96).
            call_count: Number of charges made (uint32).

        Returns:
            0x-prefixed hex signature.
        """
        # Encode UUID string as bytes32 (ASCII chars padded to 32 bytes).
        tab_id_bytes = tab_id.encode("ascii")[:32].ljust(32, b"\x00")
        tab_id_hex = "0x" + tab_id_bytes.hex()

        domain = {
            "name": "RemitTab",
            "version": "1",
            "chainId": self._chain_id,
            "verifyingContract": tab_contract,
        }
        types: dict[str, object] = {
            "TabCharge": [
                {"name": "tabId", "type": "bytes32"},
                {"name": "totalCharged", "type": "uint96"},
                {"name": "callCount", "type": "uint32"},
            ],
        }
        message = {
            "tabId": tab_id_hex,
            "totalCharged": total_charged,
            "callCount": call_count,
        }

        return await self._signer.sign_typed_data(domain, types, message)

    # ─── Streaming ────────────────────────────────────────────────────────────

    async def open_stream(
        self,
        to: str,
        rate: float,
        max_total: float,
        permit: PermitSignature | None = None,
    ) -> Stream:
        resolved = permit if permit is not None else await self._auto_permit("stream", max_total)
        body: dict[str, Any] = {
            "chain": self.chain,
            "payee": to,
            "rate_per_second": rate,
            "max_total": max_total,
        }
        if resolved is not None:
            body["permit"] = resolved.to_dict()
        data = await self._http.post("/api/v1/streams", body)
        return Stream.model_validate(data)

    async def close_stream(self, stream_id: str) -> Transaction:
        data = await self._http.post(f"/api/v1/streams/{stream_id}/close")
        return Transaction.model_validate(data)

    # ─── Bounties ─────────────────────────────────────────────────────────────

    async def post_bounty(
        self,
        amount: float,
        task: str,
        deadline: int,
        max_attempts: int = 10,
        permit: PermitSignature | None = None,
    ) -> Bounty:
        resolved = permit if permit is not None else await self._auto_permit("bounty", amount)
        body: dict[str, Any] = {
            "chain": self.chain,
            "amount": amount,
            "task_description": task,
            "deadline": deadline,
            "max_attempts": max_attempts,
        }
        if resolved is not None:
            body["permit"] = resolved.to_dict()
        data = await self._http.post("/api/v1/bounties", body)
        return Bounty.model_validate(data)

    async def submit_bounty(
        self,
        bounty_id: str,
        evidence_hash: str,
        evidence_uri: str | None = None,
    ) -> dict[str, Any]:
        """Submit evidence for a bounty. Returns BountySubmission (with ``id``)."""
        body: dict[str, Any] = {"evidence_hash": evidence_hash}
        if evidence_uri is not None:
            body["evidence_uri"] = evidence_uri
        result: dict[str, Any] = await self._http.post(
            f"/api/v1/bounties/{bounty_id}/submit",
            body,
        )
        return result

    async def award_bounty(self, bounty_id: str, submission_id: int) -> Bounty:
        """Award a bounty to a specific submission (poster-only)."""
        data = await self._http.post(
            f"/api/v1/bounties/{bounty_id}/award",
            {"submission_id": submission_id},
        )
        return Bounty.model_validate(data)

    # ─── Deposits ─────────────────────────────────────────────────────────────

    async def place_deposit(
        self,
        to: str,
        amount: float,
        expires: int,
        permit: PermitSignature | None = None,
    ) -> Deposit:
        resolved = permit if permit is not None else await self._auto_permit("deposit", amount)
        expiry = int(time.time()) + expires
        body: dict[str, Any] = {
            "chain": self.chain,
            "provider": to,
            "amount": amount,
            "expiry": expiry,
        }
        if resolved is not None:
            body["permit"] = resolved.to_dict()
        data = await self._http.post("/api/v1/deposits", body)
        return Deposit.model_validate(data)

    async def return_deposit(self, deposit_id: str) -> Transaction:
        """Provider returns a deposit (full refund to depositor, no fee)."""
        data = await self._http.post(f"/api/v1/deposits/{deposit_id}/return", {})
        return Transaction.model_validate(data)

    # ─── Events ───────────────────────────────────────────────────────────────

    def on(self, event: str, callback: Callable[..., Any]) -> None:
        """Register a callback for a specific event type (polling-based)."""
        self._callbacks.setdefault(event, []).append(callback)

    # ─── Status / balance ─────────────────────────────────────────────────────

    async def status(self) -> WalletStatus:
        return await self.get_status(self.address)

    async def balance(self) -> float:
        # Server does not track on-chain USDC balance — requires direct chain query.
        raise NotImplementedError("balance() requires on-chain query (not yet implemented)")

    # ─── One-time operator links ───────────────────────────────────────────────

    async def create_fund_link(
        self,
        messages: list[dict[str, str]] | None = None,
        agent_name: str | None = None,
        permit: PermitSignature | None = None,
    ) -> LinkResponse:
        """Generate a one-time URL for the operator to fund this wallet.

        Also auto-signs a permit so the operator can withdraw from the same link.

        Args:
            messages: Optional list of dicts with ``role`` ("agent"/"system") and ``text``.
            agent_name: Optional agent display name shown on the funding page.
            permit: Optional pre-signed permit. Auto-signed if omitted.
        """
        if permit is None:
            permit = await self._auto_permit("relayer", 999_999_999.0)
        body: dict[str, Any] = {}
        if messages is not None:
            body["messages"] = messages
        if agent_name is not None:
            body["agent_name"] = agent_name
        if permit is not None:
            body["permit"] = permit.to_dict()
        data = await self._http.post("/api/v1/links/fund", body)
        return LinkResponse.model_validate(data)

    async def create_withdraw_link(
        self,
        messages: list[dict[str, str]] | None = None,
        agent_name: str | None = None,
        permit: PermitSignature | None = None,
    ) -> LinkResponse:
        """Generate a one-time URL for the operator to withdraw funds.

        Non-custodial: auto-signs an EIP-2612 permit approving the server
        relayer to transfer USDC from the agent's wallet. If a permit is
        provided it is used as-is; otherwise one is signed automatically.

        Args:
            messages: Optional list of dicts with ``role`` ("agent"/"system") and ``text``.
            agent_name: Optional agent display name shown on the withdraw page.
            permit: Optional pre-signed permit. Auto-signed if omitted.
        """
        if permit is None:
            permit = await self._auto_permit("relayer", 999_999_999.0)
        body: dict[str, Any] = {}
        if messages is not None:
            body["messages"] = messages
        if agent_name is not None:
            body["agent_name"] = agent_name
        if permit is not None:
            body["permit"] = permit.to_dict()
        data = await self._http.post("/api/v1/links/withdraw", body)
        return LinkResponse.model_validate(data)

    # ─── Webhooks ─────────────────────────────────────────────────────────────

    async def register_webhook(
        self,
        url: str,
        events: list[str],
        chains: list[str] | None = None,
    ) -> Webhook:
        body: dict[str, Any] = {"url": url, "events": events}
        if chains is not None:
            body["chains"] = chains
        data = await self._http.post("/api/v1/webhooks", body)
        return Webhook.model_validate(data)

    # ─── Testnet ──────────────────────────────────────────────────────────────

    async def request_testnet_funds(self) -> Transaction:
        if not self.testnet:
            raise ValueError("request_testnet_funds() is only available on testnet")
        data = await self._http.post("/api/v1/faucet", {"wallet": self.address})
        # Server returns FaucetResponse {tx_hash, amount, recipient} — not a full Transaction.
        return Transaction(
            tx_hash=data.get("tx_hash"),
            chain=self.chain,
            status="confirmed",
            created_at=int(time.time()),
        )

    async def mint(self, amount: float) -> dict[str, Any]:
        """Mint testnet USDC. Returns ``{"tx_hash": "0x…", "balance": "…"}``."""
        import httpx  # noqa: PLC0415

        # Mint is a public endpoint — use raw HTTP without auth.
        base = self._http._base_url.rstrip("/")
        url = f"{base}/api/v1/mint" if "/api/v1" not in base else f"{base}/mint"

        async with httpx.AsyncClient() as client:
            resp = await client.post(
                url,
                json={"wallet": self.address, "amount": amount},
            )
            if not resp.is_success:
                ct = resp.headers.get("content-type", "")
                data = resp.json() if ct.startswith("application/json") else {}
                msg = data.get("message", resp.text) if isinstance(data, dict) else resp.text
                raise RuntimeError(f"mint failed ({resp.status_code}): {msg}")
            return resp.json()  # type: ignore[no-any-return]

    # ─── x402 ──────────────────────────────────────────────────────────────

    async def x402_fetch(
        self,
        url: str,
        max_auto_pay_usdc: float = 0.10,
    ) -> tuple[Any, dict[str, Any] | None]:
        """Make an HTTP request, auto-paying any x402 402 response.

        Returns:
            A tuple of ``(response, last_payment)``. ``last_payment`` is the
            decoded PAYMENT-REQUIRED header (including V2 fields like
            ``resource``, ``description``, ``mimeType``) or ``None``.
        """
        from remitmd.x402 import X402Client  # noqa: PLC0415

        client = X402Client(wallet=self, max_auto_pay_usdc=max_auto_pay_usdc)
        async with client:
            response = await client.get(url)
            return response, client.last_payment

    # ─── Repr (never expose key) ──────────────────────────────────────────────

    def __repr__(self) -> str:
        return f"Wallet(address={self.address!r}, chain={self.chain!r})"

    def __str__(self) -> str:
        return self.__repr__()

    # Prevent accidental serialisation that might include signer internals
    def __reduce__(self) -> tuple[Any, ...]:
        raise TypeError("Wallet objects cannot be pickled (would expose key material)")
