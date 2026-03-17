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
from remitmd.models.tab import Tab
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
            "value": self.value, "deadline": self.deadline,
            "v": self.v, "r": self.r, "s": self.s,
        }


# Default USDC contract addresses per chain.
USDC_ADDRESSES: dict[str, str] = {
    "base-sepolia": "0x142aD61B8d2edD6b3807D9266866D97C35Ee0317",
    "base": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    "localhost": "0x5FbDB2315678afecb367f032d93F642f64180aa3",
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
            A PermitSignature that can be passed to post_bounty() or place_deposit().
        """
        usdc_addr = usdc_address or USDC_ADDRESSES.get(self.chain, "")

        domain = {
            "name": "USD Coin",
            "version": "2",
            "chainId": self._chain_id,
            "verifyingContract": usdc_addr,
        }
        types = {
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

    # ─── Direct payment ───────────────────────────────────────────────────────

    async def pay_direct(self, to: str, amount: float, memo: str = "") -> Transaction:
        """Send a direct USDC payment (no escrow, no refund)."""
        nonce = secrets.token_hex(16)
        data = await self._http.post(
            "/api/v0/payments/direct",
            {
                "to": to,
                "amount": amount,
                "task": memo,
                "chain": self.chain,
                "nonce": nonce,
                "signature": "0x",
            },
        )
        return Transaction.model_validate(data)

    # ─── Escrow ───────────────────────────────────────────────────────────────

    async def pay(self, invoice: Invoice) -> Escrow:
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
        await self._http.post("/api/v0/invoices", inv_body)

        # Step 2: fund the escrow.
        data = await self._http.post(
            "/api/v0/escrows",
            {"invoice_id": invoice_id},
        )
        return Escrow.model_validate(data)

    async def claim_start(self, invoice_id: str) -> Escrow:
        """Payee calls this to start work and begin the escrow timer."""
        data = await self._http.post(f"/api/v0/escrows/{invoice_id}/claim-start", {})
        return Escrow.model_validate(data)

    async def submit_evidence(
        self,
        invoice_id: str,
        evidence_uri: str,
    ) -> Escrow:
        data = await self._http.post(
            f"/api/v0/escrows/{invoice_id}/claim-start",
            {"evidence_uri": evidence_uri},
        )
        return Escrow.model_validate(data)

    async def release_escrow(self, invoice_id: str) -> Escrow:
        data = await self._http.post(f"/api/v0/escrows/{invoice_id}/release", {})
        return Escrow.model_validate(data)

    async def release_milestone(self, invoice_id: str, milestone_index: int) -> Escrow:
        data = await self._http.post(
            f"/api/v0/escrows/{invoice_id}/release",
            {"milestone_ids": [str(milestone_index)]},
        )
        return Escrow.model_validate(data)

    async def cancel_escrow(self, invoice_id: str) -> Escrow:
        data = await self._http.post(f"/api/v0/escrows/{invoice_id}/cancel", {})
        return Escrow.model_validate(data)

    # ─── Metered tabs ─────────────────────────────────────────────────────────

    async def open_tab(
        self,
        to: str,
        limit: float,
        per_unit: float,
        expires: int = 86400,
    ) -> Tab:
        expiry = int(time.time()) + expires
        data = await self._http.post(
            "/api/v0/tabs",
            {
                "chain": self.chain,
                "provider": to,
                "limit_amount": limit,
                "per_unit": per_unit,
                "expiry": expiry,
            },
        )
        return Tab.model_validate(data)

    async def close_tab(self, tab_id: str) -> Tab:
        data = await self._http.post(
            f"/api/v0/tabs/{tab_id}/close",
            {"final_amount": 0, "provider_sig": "0x"},
        )
        return Tab.model_validate(data)

    # ─── Streaming ────────────────────────────────────────────────────────────

    async def open_stream(
        self,
        to: str,
        rate: float,
        max_duration: int = 3600,
        max_total: float | None = None,
    ) -> Stream:
        body: dict[str, Any] = {
            "chain": self.chain,
            "to": to,
            "rate": rate,
            "max_duration": max_duration,
        }
        if max_total is not None:
            body["max_total"] = max_total
        data = await self._http.post("/api/v0/streams", body)
        return Stream.model_validate(data)

    async def close_stream(self, stream_id: str) -> Transaction:
        data = await self._http.post(f"/api/v0/streams/{stream_id}/close")
        return Transaction.model_validate(data)

    # ─── Bounties ─────────────────────────────────────────────────────────────

    async def post_bounty(
        self,
        amount: float,
        task: str,
        deadline: int,
        validation: str = "poster",
        max_attempts: int = 10,
        permit: PermitSignature | None = None,
    ) -> Bounty:
        body: dict[str, Any] = {
            "chain": self.chain,
            "amount": amount,
            "task": task,
            "deadline": deadline,
            "validation": validation,
            "max_attempts": max_attempts,
        }
        if permit is not None:
            body["permit"] = permit.to_dict()
        data = await self._http.post("/api/v0/bounties", body)
        return Bounty.model_validate(data)

    async def submit_bounty(self, bounty_id: str, evidence_uri: str) -> Transaction:
        data = await self._http.post(
            f"/api/v0/bounties/{bounty_id}/submit",
            {"evidence_uri": evidence_uri},
        )
        return Transaction.model_validate(data)

    async def award_bounty(self, bounty_id: str, winner: str) -> Transaction:
        data = await self._http.post(
            f"/api/v0/bounties/{bounty_id}/award",
            {"winner": winner},
        )
        return Transaction.model_validate(data)

    # ─── Deposits ─────────────────────────────────────────────────────────────

    async def place_deposit(
        self,
        to: str,
        amount: float,
        expires: int,
        permit: PermitSignature | None = None,
    ) -> Deposit:
        body: dict[str, Any] = {"to": to, "amount": amount, "expires": expires}
        if permit is not None:
            body["permit"] = permit.to_dict()
        data = await self._http.post("/api/v0/deposits", body)
        return Deposit.model_validate(data)

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

    async def create_fund_link(self) -> LinkResponse:
        """Generate a one-time URL for the operator to fund this wallet."""
        data = await self._http.post("/api/v0/links/fund", {})
        return LinkResponse.model_validate(data)

    async def create_withdraw_link(self) -> LinkResponse:
        """Generate a one-time URL for the operator to withdraw funds."""
        data = await self._http.post("/api/v0/links/withdraw", {})
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
        data = await self._http.post("/api/v0/webhooks", body)
        return Webhook.model_validate(data)

    # ─── Testnet ──────────────────────────────────────────────────────────────

    async def request_testnet_funds(self) -> Transaction:
        if not self.testnet:
            raise ValueError("request_testnet_funds() is only available on testnet")
        data = await self._http.post("/api/v0/faucet", {"wallet": self.address})
        # Server returns FaucetResponse {tx_hash, amount, recipient} — not a full Transaction.
        return Transaction(
            tx_hash=data.get("tx_hash"),
            chain=self.chain,
            status="confirmed",
            created_at=int(time.time()),
        )

    # ─── Repr (never expose key) ──────────────────────────────────────────────

    def __repr__(self) -> str:
        return f"Wallet(address={self.address!r}, chain={self.chain!r})"

    def __str__(self) -> str:
        return self.__repr__()

    # Prevent accidental serialisation that might include signer internals
    def __reduce__(self) -> tuple[Any, ...]:
        raise TypeError("Wallet objects cannot be pickled (would expose key material)")
