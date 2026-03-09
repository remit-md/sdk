"""Wallet — read + write client (requires a private key or custom Signer)."""

from __future__ import annotations

import os
import secrets
from collections.abc import Callable
from typing import Any

from remitmd._http import AuthenticatedClient, get_chain_config
from remitmd.client import RemitClient
from remitmd.models.bounty import Bounty
from remitmd.models.common import Transaction, WalletStatus, Webhook
from remitmd.models.deposit import Deposit
from remitmd.models.dispute import Dispute
from remitmd.models.invoice import Invoice
from remitmd.models.stream import Stream
from remitmd.models.tab import Tab
from remitmd.signer import PrivateKeySigner, Signer


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
    ) -> None:
        if private_key is None and signer is None:
            raise ValueError("Provide either private_key or a Signer instance")
        if private_key is not None and signer is not None:
            raise ValueError("Provide private_key OR signer, not both")

        chain_id, url = get_chain_config(chain, testnet, api_url)
        self.chain = chain
        self.testnet = testnet

        self._signer: Signer = signer if signer is not None else PrivateKeySigner(private_key)  # type: ignore[arg-type]
        self._http = AuthenticatedClient(url, signer=self._signer, chain_id=chain_id)

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

    # ─── Direct payment ───────────────────────────────────────────────────────

    async def pay_direct(self, to: str, amount: float, memo: str = "") -> Transaction:
        """Send a direct USDC payment (no escrow, no refund)."""
        data = await self._http.post(
            "/v1/payments/direct",
            {"to": to, "amount": amount, "memo": memo},
        )
        return Transaction.model_validate(data)

    # ─── Escrow ───────────────────────────────────────────────────────────────

    async def pay(self, invoice: Invoice) -> Transaction:
        """Fund an escrow from a structured Invoice object."""
        data = await self._http.post(
            "/v1/escrows",
            invoice.model_dump(exclude_none=True),
        )
        return Transaction.model_validate(data)

    async def claim_start(self, invoice_id: str) -> Transaction:
        """Payee calls this to start work and begin the escrow timer."""
        data = await self._http.post(f"/v1/escrows/{invoice_id}/claim-start")
        return Transaction.model_validate(data)

    async def submit_evidence(
        self,
        invoice_id: str,
        evidence_uri: str,
        milestone_index: int = 0,
    ) -> Transaction:
        data = await self._http.post(
            f"/v1/escrows/{invoice_id}/submit-evidence",
            {"evidence_uri": evidence_uri, "milestone_index": milestone_index},
        )
        return Transaction.model_validate(data)

    async def release_escrow(self, invoice_id: str) -> Transaction:
        data = await self._http.post(f"/v1/escrows/{invoice_id}/release")
        return Transaction.model_validate(data)

    async def release_milestone(self, invoice_id: str, milestone_index: int) -> Transaction:
        data = await self._http.post(
            f"/v1/escrows/{invoice_id}/release-milestone",
            {"milestone_index": milestone_index},
        )
        return Transaction.model_validate(data)

    async def cancel_escrow(self, invoice_id: str) -> Transaction:
        data = await self._http.post(f"/v1/escrows/{invoice_id}/cancel")
        return Transaction.model_validate(data)

    # ─── Metered tabs ─────────────────────────────────────────────────────────

    async def open_tab(
        self,
        to: str,
        limit: float,
        per_unit: float,
        expires: int = 86400,
    ) -> Tab:
        data = await self._http.post(
            "/v1/tabs",
            {"to": to, "limit": limit, "per_unit": per_unit, "expires": expires},
        )
        return Tab.model_validate(data)

    async def close_tab(self, tab_id: str) -> Transaction:
        data = await self._http.post(f"/v1/tabs/{tab_id}/close")
        return Transaction.model_validate(data)

    # ─── Streaming ────────────────────────────────────────────────────────────

    async def open_stream(
        self,
        to: str,
        rate: float,
        max_duration: int = 3600,
        max_total: float | None = None,
    ) -> Stream:
        body: dict[str, Any] = {"to": to, "rate": rate, "max_duration": max_duration}
        if max_total is not None:
            body["max_total"] = max_total
        data = await self._http.post("/v1/streams", body)
        return Stream.model_validate(data)

    async def close_stream(self, stream_id: str) -> Transaction:
        data = await self._http.post(f"/v1/streams/{stream_id}/close")
        return Transaction.model_validate(data)

    # ─── Subscriptions ────────────────────────────────────────────────────────

    async def subscribe(
        self,
        to: str,
        amount: float,
        interval: str = "monthly",
        max_periods: int | None = None,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {"to": to, "amount": amount, "interval": interval}
        if max_periods is not None:
            body["max_periods"] = max_periods
        return await self._http.post("/v1/subscriptions", body)  # type: ignore[return-value,no-any-return]

    async def cancel_subscription(self, sub_id: str) -> Transaction:
        data = await self._http.post(f"/v1/subscriptions/{sub_id}/cancel")
        return Transaction.model_validate(data)

    # ─── Bounties ─────────────────────────────────────────────────────────────

    async def post_bounty(
        self,
        amount: float,
        task: str,
        deadline: int,
        validation: str = "poster",
        max_attempts: int = 10,
    ) -> Bounty:
        data = await self._http.post(
            "/v1/bounties",
            {
                "amount": amount,
                "task": task,
                "deadline": deadline,
                "validation": validation,
                "max_attempts": max_attempts,
            },
        )
        return Bounty.model_validate(data)

    async def submit_bounty(self, bounty_id: str, evidence_uri: str) -> Transaction:
        data = await self._http.post(
            f"/v1/bounties/{bounty_id}/submit",
            {"evidence_uri": evidence_uri},
        )
        return Transaction.model_validate(data)

    async def award_bounty(self, bounty_id: str, winner: str) -> Transaction:
        data = await self._http.post(
            f"/v1/bounties/{bounty_id}/award",
            {"winner": winner},
        )
        return Transaction.model_validate(data)

    # ─── Deposits ─────────────────────────────────────────────────────────────

    async def place_deposit(self, to: str, amount: float, expires: int) -> Deposit:
        data = await self._http.post(
            "/v1/deposits",
            {"to": to, "amount": amount, "expires": expires},
        )
        return Deposit.model_validate(data)

    # ─── Disputes ─────────────────────────────────────────────────────────────

    async def file_dispute(
        self,
        invoice_id: str,
        reason: str,
        details: str,
        evidence_uri: str,
    ) -> Dispute:
        data = await self._http.post(
            "/v1/disputes",
            {
                "invoice_id": invoice_id,
                "reason": reason,
                "details": details,
                "evidence_uri": evidence_uri,
            },
        )
        return Dispute.model_validate(data)

    # ─── Events ───────────────────────────────────────────────────────────────

    def on(self, event: str, callback: Callable[..., Any]) -> None:
        """Register a callback for a specific event type (polling-based)."""
        self._callbacks.setdefault(event, []).append(callback)

    # ─── Status / balance ─────────────────────────────────────────────────────

    async def status(self) -> WalletStatus:
        return await self.get_status(self.address)

    async def balance(self) -> float:
        ws = await self.status()
        return ws.usdc_balance

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
        data = await self._http.post("/v1/webhooks", body)
        return Webhook.model_validate(data)

    # ─── Testnet ──────────────────────────────────────────────────────────────

    async def request_testnet_funds(self) -> Transaction:
        if not self.testnet:
            raise ValueError("request_testnet_funds() is only available on testnet")
        data = await self._http.post("/v1/faucet", {"address": self.address})
        return Transaction.model_validate(data)

    # ─── Repr (never expose key) ──────────────────────────────────────────────

    def __repr__(self) -> str:
        return f"Wallet(address={self.address!r}, chain={self.chain!r})"

    def __str__(self) -> str:
        return self.__repr__()

    # Prevent accidental serialisation that might include signer internals
    def __reduce__(self) -> tuple[Any, ...]:
        raise TypeError("Wallet objects cannot be pickled (would expose key material)")
