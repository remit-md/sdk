"""MockRemit — in-memory mock for fast (<1ms) unit tests.

Does not require a running API server, chain, or database.
Simulates the full state machine so agents can be tested without infrastructure.

Usage:
    mock = MockRemit()
    payer = mock.create_wallet(balance=100.0)
    payee = mock.create_wallet()

    tab = await payer.open_tab(payee.address, limit=10.0, per_unit=0.01)
    await payer.close_tab(tab.id)
"""

from __future__ import annotations

import secrets
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from remitmd.errors import (
    BountyNotFound,
    DepositNotFound,
    EscrowNotFound,
    InsufficientBalance,
    InvalidState,
    TabLimitExceeded,
    TabNotFound,
)
from remitmd.models.bounty import Bounty, BountySubmission
from remitmd.models.common import (
    BountyStatus,
    DepositStatus,
    EscrowStatus,
    LinkResponse,
    Reputation,
    StreamStatus,
    TabStatus,
    Transaction,
    WalletStatus,
    Webhook,
)
from remitmd.models.deposit import Deposit
from remitmd.models.escrow import Escrow
from remitmd.models.invoice import Invoice
from remitmd.models.stream import Stream
from remitmd.models.tab import Tab


def _id(prefix: str) -> str:
    return f"{prefix}_{secrets.token_hex(8)}"


def _now() -> int:
    return int(time.time())


def _iso(ts: int | None = None) -> str:
    """Return an ISO-8601 timestamp string (UTC)."""
    t = ts if ts is not None else _now()
    return datetime.fromtimestamp(t, tz=timezone.utc).isoformat()


@dataclass
class _MockState:
    """All in-memory state for MockRemit."""

    balances: dict[str, float] = field(default_factory=dict)
    escrows: dict[str, Escrow] = field(default_factory=dict)
    tabs: dict[str, Tab] = field(default_factory=dict)
    streams: dict[str, Stream] = field(default_factory=dict)
    bounties: dict[str, Bounty] = field(default_factory=dict)
    deposits: dict[str, Deposit] = field(default_factory=dict)
    forced_errors: dict[str, str] = field(default_factory=dict)  # address → error code
    time_offset: int = 0  # seconds added to _now()


class MockRemit:
    """
    In-memory mock of the remit.md protocol.

    All state is kept in Python dicts. No network, no chain.
    Operations complete in <1ms.
    """

    def __init__(self) -> None:
        self._state = _MockState()

    # ─── Wallet factory ───────────────────────────────────────────────────────

    def create_wallet(self, balance: float = 1000.0) -> MockWallet:
        """Create a mock wallet with a given USDC balance."""
        address = "0x" + secrets.token_hex(20)
        self._state.balances[address] = balance
        return MockWallet(address=address, mock=self)

    # ─── Fault injection ──────────────────────────────────────────────────────

    def set_behavior(self, wallet_address: str, error_code: str) -> None:
        """Force the next operation for a wallet to raise the given error code."""
        self._state.forced_errors[wallet_address] = error_code

    def clear_behavior(self, wallet_address: str) -> None:
        self._state.forced_errors.pop(wallet_address, None)

    # ─── Time control ─────────────────────────────────────────────────────────

    def advance_time(self, seconds: int) -> None:
        """Simulate time passing. Affects timeout checks."""
        self._state.time_offset += seconds

    def now(self) -> int:
        return _now() + self._state.time_offset

    # ─── Internal helpers ─────────────────────────────────────────────────────

    def _check_forced_error(self, address: str) -> None:
        code = self._state.forced_errors.pop(address, None)
        if code is not None:
            from remitmd.errors import from_error_code

            raise from_error_code(code, f"Forced error: {code}", 400)

    def _debit(self, address: str, amount: float) -> None:
        balance = self._state.balances.get(address, 0.0)
        if balance < amount:
            raise InsufficientBalance(
                f"Insufficient balance: have {balance:.2f}, need {amount:.2f}"
            )
        self._state.balances[address] = balance - amount

    def _credit(self, address: str, amount: float) -> None:
        self._state.balances[address] = self._state.balances.get(address, 0.0) + amount

    def _make_tx(self, invoice_id: str | None = None) -> Transaction:
        return Transaction(
            invoice_id=invoice_id,
            tx_hash="0x" + secrets.token_hex(32),
            chain="mock",
            status="confirmed",
            created_at=self.now(),
        )


class MockWallet:
    """
    A wallet backed by MockRemit.

    Has the same async API as the real Wallet class.
    Does not use a private key; addresses are randomly generated.
    """

    def __init__(self, address: str, mock: MockRemit) -> None:
        self.address = address
        self.chain = "mock"
        self.testnet = True
        self._mock = mock

    # ─── Status ───────────────────────────────────────────────────────────────

    async def balance(self) -> float:
        return self._mock._state.balances.get(self.address, 0.0)

    async def status(self) -> WalletStatus:
        return WalletStatus(
            wallet=self.address,
            tier="free",
            monthly_volume=0.0,
            fee_rate_bps=30,
        )

    async def get_reputation(self, wallet: str) -> Reputation:
        return Reputation(
            address=wallet,
            score=1.0,
            total_paid=0.0,
            total_received=0.0,
            escrows_completed=0,
            member_since=self._mock.now(),
        )

    # ─── Direct payment ───────────────────────────────────────────────────────

    async def pay_direct(self, to: str, amount: float, memo: str = "") -> Transaction:
        self._mock._check_forced_error(self.address)
        self._mock._debit(self.address, amount)
        self._mock._credit(to, amount)
        return self._mock._make_tx()

    # ─── Escrow ───────────────────────────────────────────────────────────────

    async def pay(self, invoice: Invoice) -> Transaction:
        self._mock._check_forced_error(self.address)
        self._mock._debit(self.address, invoice.amount)

        invoice_id = invoice.id or _id("inv")
        now = _iso(self._mock.now())
        timeout = _iso(self._mock.now() + invoice.timeout)
        escrow = Escrow(
            invoice_id=invoice_id,
            chain="mock",
            tx_hash="0x" + secrets.token_hex(32),
            status=EscrowStatus.funded,
            payer=self.address,
            payee=invoice.to,
            amount=invoice.amount,
            fee=0.0,
            timeout=timeout,
            created_at=now,
            updated_at=now,
        )
        self._mock._state.escrows[invoice_id] = escrow
        return self._mock._make_tx(invoice_id=invoice_id)

    async def release_escrow(self, invoice_id: str) -> Transaction:
        self._mock._check_forced_error(self.address)
        escrow = self._find_escrow_by_invoice(invoice_id)
        if escrow.status not in (EscrowStatus.funded, EscrowStatus.active):
            raise InvalidState(f"Escrow is {escrow.status}, expected funded or active")
        self._mock._credit(escrow.payee, escrow.amount)
        escrow.status = EscrowStatus.completed
        return self._mock._make_tx(invoice_id=invoice_id)

    async def cancel_escrow(self, invoice_id: str) -> Transaction:
        self._mock._check_forced_error(self.address)
        escrow = self._find_escrow_by_invoice(invoice_id)
        if escrow.status != EscrowStatus.funded:
            raise InvalidState(f"Escrow is {escrow.status}, expected funded")
        self._mock._credit(self.address, escrow.amount)
        escrow.status = EscrowStatus.cancelled
        return self._mock._make_tx(invoice_id=invoice_id)

    async def claim_start(self, invoice_id: str) -> Transaction:
        self._mock._check_forced_error(self.address)
        escrow = self._find_escrow_by_invoice(invoice_id)
        if escrow.status != EscrowStatus.funded:
            raise InvalidState(f"Escrow is {escrow.status}")
        escrow.status = EscrowStatus.active
        return self._mock._make_tx(invoice_id=invoice_id)

    async def submit_evidence(
        self, invoice_id: str, evidence_uri: str, milestone_index: int = 0
    ) -> Transaction:
        self._mock._check_forced_error(self.address)
        self._find_escrow_by_invoice(invoice_id)  # validates existence
        return self._mock._make_tx(invoice_id=invoice_id)

    async def release_milestone(self, invoice_id: str, milestone_index: int) -> Transaction:
        self._mock._check_forced_error(self.address)
        self._find_escrow_by_invoice(invoice_id)
        return self._mock._make_tx(invoice_id=invoice_id)

    def _find_escrow_by_invoice(self, invoice_id: str) -> Escrow:
        for escrow in self._mock._state.escrows.values():
            if escrow.invoice_id == invoice_id:
                return escrow
        raise EscrowNotFound(f"No escrow for invoice {invoice_id!r}")

    # ─── Tabs ─────────────────────────────────────────────────────────────────

    async def open_tab(self, to: str, limit: float, per_unit: float, expires: int = 86400) -> Tab:
        self._mock._check_forced_error(self.address)
        # Reserve funds up-front
        self._mock._debit(self.address, limit)

        tid = _id("tab")
        now = _iso(self._mock.now())
        expiry = _iso(self._mock.now() + expires)
        tab = Tab(
            id=tid,
            chain="mock",
            payer=self.address,
            provider=to,
            limit_amount=limit,
            per_unit=per_unit,
            total_charged=0.0,
            call_count=0,
            status=TabStatus.open,
            expiry=expiry,
            tx_hash="0x" + secrets.token_hex(32),
            created_at=now,
            updated_at=now,
        )
        self._mock._state.tabs[tid] = tab
        return tab

    async def close_tab(self, tab_id: str) -> Transaction:
        self._mock._check_forced_error(self.address)
        tab = self._mock._state.tabs.get(tab_id)
        if tab is None:
            raise TabNotFound(f"Tab {tab_id!r} not found")
        if tab.status != TabStatus.open:
            raise InvalidState(f"Tab is {tab.status}, expected open")

        remaining = tab.limit_amount - tab.total_charged
        # Settle: provider gets charged amount, payer gets remaining back
        self._mock._credit(tab.provider, tab.total_charged)
        self._mock._credit(self.address, remaining)
        tab.status = TabStatus.closed
        return self._mock._make_tx()

    async def charge_tab(self, tab_id: str, units: float) -> Transaction:
        """Payee charges units against an open tab (not in Wallet API but useful in tests)."""
        tab = self._mock._state.tabs.get(tab_id)
        if tab is None:
            raise TabNotFound(f"Tab {tab_id!r} not found")
        amount = units * tab.per_unit
        remaining = tab.limit_amount - tab.total_charged
        if amount > remaining:
            raise TabLimitExceeded(f"Charge {amount:.2f} exceeds remaining {remaining:.2f}")
        tab.total_charged += amount
        tab.call_count += 1
        return self._mock._make_tx()

    # ─── Streams ──────────────────────────────────────────────────────────────

    async def open_stream(
        self,
        to: str,
        rate: float,
        max_duration: int = 3600,
        max_total: float | None = None,
    ) -> Stream:
        self._mock._check_forced_error(self.address)
        total = max_total or (rate * max_duration)
        self._mock._debit(self.address, total)

        sid = _id("stm")
        stream = Stream(
            id=sid,
            payer=self.address,
            payee=to,
            rate_per_second=rate,
            max_duration=max_duration,
            max_total=max_total,
            streamed=0.0,
            claimable=0.0,
            status=StreamStatus.active,
            started_at=self._mock.now(),
            ends_at=self._mock.now() + max_duration,
            chain="mock",
            created_at=self._mock.now(),
            updated_at=self._mock.now(),
        )
        self._mock._state.streams[sid] = stream
        return stream

    async def close_stream(self, stream_id: str) -> Transaction:
        self._mock._check_forced_error(self.address)
        stream = self._mock._state.streams.get(stream_id)
        if stream is None:
            from remitmd.errors import StreamNotFound

            raise StreamNotFound(f"Stream {stream_id!r} not found")

        elapsed = self._mock.now() - int(stream.started_at)
        streamed = min(stream.rate_per_second * elapsed, (stream.max_total or float("inf")))
        max_total = stream.max_total or (stream.rate_per_second * (stream.max_duration or 0))
        remaining = max_total - streamed

        self._mock._credit(stream.payee, streamed)
        self._mock._credit(self.address, remaining)

        stream.status = StreamStatus.closed
        stream.streamed = streamed
        return self._mock._make_tx()

    # ─── Bounties ─────────────────────────────────────────────────────────────

    async def post_bounty(
        self,
        amount: float,
        task: str,
        deadline: int,
        validation: str = "poster",
        max_attempts: int = 10,
    ) -> Bounty:
        self._mock._check_forced_error(self.address)
        self._mock._debit(self.address, amount)

        bid = _id("bnt")
        bounty = Bounty(
            id=bid,
            poster=self.address,
            amount=amount,
            task=task,
            deadline=deadline,
            validation=validation,
            max_attempts=max_attempts,
            attempts=0,
            winner=None,
            status=BountyStatus.open,
            submissions=[],
            chain="mock",
            created_at=self._mock.now(),
            updated_at=self._mock.now(),
        )
        self._mock._state.bounties[bid] = bounty
        return bounty

    async def submit_bounty(self, bounty_id: str, evidence_uri: str) -> Transaction:
        self._mock._check_forced_error(self.address)
        bounty = self._mock._state.bounties.get(bounty_id)
        if bounty is None:
            raise BountyNotFound(f"Bounty {bounty_id!r} not found")
        sub = BountySubmission(
            id=_id("sub"),
            bounty_id=bounty_id,
            submitter=self.address,
            evidence_uri=evidence_uri,
            status="pending",
            submitted_at=self._mock.now(),
        )
        if bounty.submissions is None:
            bounty.submissions = []
        bounty.submissions.append(sub)
        bounty.attempts += 1
        return self._mock._make_tx()

    async def award_bounty(self, bounty_id: str, winner: str) -> Transaction:
        self._mock._check_forced_error(self.address)
        bounty = self._mock._state.bounties.get(bounty_id)
        if bounty is None:
            raise BountyNotFound(f"Bounty {bounty_id!r} not found")
        if bounty.status != BountyStatus.open:
            raise InvalidState(f"Bounty is {bounty.status}")
        self._mock._credit(winner, bounty.amount)
        bounty.winner = winner
        bounty.status = BountyStatus.awarded
        return self._mock._make_tx()

    # ─── Deposits ─────────────────────────────────────────────────────────────

    async def place_deposit(self, to: str, amount: float, expires: int) -> Deposit:
        self._mock._check_forced_error(self.address)
        self._mock._debit(self.address, amount)

        did = _id("dep")
        deposit = Deposit(
            id=did,
            payer=self.address,
            payee=to,
            amount=amount,
            expires_at=self._mock.now() + expires,
            status=DepositStatus.locked,
            tx_hash="0x" + secrets.token_hex(32),
            chain="mock",
            created_at=self._mock.now(),
            updated_at=self._mock.now(),
        )
        self._mock._state.deposits[did] = deposit
        return deposit

    async def return_deposit(self, deposit_id: str) -> Transaction:
        """Payee returns the deposit to payer."""
        deposit = self._mock._state.deposits.get(deposit_id)
        if deposit is None:
            raise DepositNotFound(f"Deposit {deposit_id!r} not found")
        if deposit.status != DepositStatus.locked:
            raise InvalidState(f"Deposit is {deposit.status}")
        self._mock._credit(deposit.payer, deposit.amount)
        deposit.status = DepositStatus.returned
        return self._mock._make_tx()

    async def forfeit_deposit(self, deposit_id: str) -> Transaction:
        """Payee forfeits the deposit (keeps the funds)."""
        deposit = self._mock._state.deposits.get(deposit_id)
        if deposit is None:
            raise DepositNotFound(f"Deposit {deposit_id!r} not found")
        if deposit.status != DepositStatus.locked:
            raise InvalidState(f"Deposit is {deposit.status}")
        self._mock._credit(deposit.payee, deposit.amount)
        deposit.status = DepositStatus.forfeited
        return self._mock._make_tx()

    # ─── Testnet faucet ───────────────────────────────────────────────────────

    async def request_testnet_funds(self) -> Transaction:
        self._mock._credit(self.address, 100.0)
        return self._mock._make_tx()

    # ─── Webhooks ─────────────────────────────────────────────────────────────

    async def register_webhook(
        self, url: str, events: list[str], chains: list[str] | None = None
    ) -> Webhook:
        return Webhook(
            id=_id("wh"),
            wallet=self.address,
            url=url,
            events=events,
            chains=chains or ["mock"],
            active=True,
            created_at=self._mock.now(),
        )

    # ─── One-time operator links ───────────────────────────────────────────────

    async def create_fund_link(self) -> LinkResponse:
        token = secrets.token_hex(16)
        return LinkResponse(
            url=f"https://remit.md/fund/{token}",
            token=token,
            expires_at=_iso(self._mock.now() + 3600),
            wallet_address=self.address,
        )

    async def create_withdraw_link(self) -> LinkResponse:
        token = secrets.token_hex(16)
        return LinkResponse(
            url=f"https://remit.md/withdraw/{token}",
            token=token,
            expires_at=_iso(self._mock.now() + 3600),
            wallet_address=self.address,
        )

    def on(self, event: str, callback: Callable[..., Any]) -> None:
        """No-op in mock: callbacks are never invoked automatically."""
        pass

    # ─── Repr ─────────────────────────────────────────────────────────────────

    def __repr__(self) -> str:
        return f"MockWallet(address={self.address!r})"
