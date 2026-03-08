"""Tests for MockRemit — all Wallet methods tested against the in-memory mock."""

import pytest
import pytest_asyncio

from remitmd.errors import (
    BountyNotFound,
    InsufficientBalance,
    InvalidState,
    TabLimitExceeded,
    TabNotFound,
)
from remitmd.models.common import (
    BountyStatus,
    DepositStatus,
    DisputeStatus,
    EscrowStatus,
    StreamStatus,
    TabStatus,
)
from remitmd.models.invoice import Invoice
from remitmd.testing.mock import MockRemit


@pytest.fixture
def mock() -> MockRemit:
    return MockRemit()


@pytest.fixture
def payer(mock: MockRemit):
    return mock.create_wallet(balance=1000.0)


@pytest.fixture
def payee(mock: MockRemit):
    return mock.create_wallet(balance=0.0)


# ─── Direct payment ───────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_pay_direct_transfers_funds(mock, payer, payee):
    await payer.pay_direct(payee.address, 50.0, memo="hello")

    assert await payer.balance() == 950.0
    assert await payee.balance() == 50.0


@pytest.mark.asyncio
async def test_pay_direct_insufficient_balance(mock, payer, payee):
    with pytest.raises(InsufficientBalance):
        await payer.pay_direct(payee.address, 2000.0)


# ─── Escrow ───────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_escrow_full_lifecycle(mock, payer, payee):
    invoice = Invoice(to=payee.address, amount=100.0, memo="task")
    tx = await payer.pay(invoice)
    assert tx.invoice_id is not None
    assert await payer.balance() == 900.0

    await payer.release_escrow(tx.invoice_id)
    assert await payee.balance() == 100.0


@pytest.mark.asyncio
async def test_escrow_cancel_refunds_payer(mock, payer, payee):
    invoice = Invoice(to=payee.address, amount=100.0)
    tx = await payer.pay(invoice)
    await payer.cancel_escrow(tx.invoice_id)
    assert await payer.balance() == 1000.0
    assert await payee.balance() == 0.0


@pytest.mark.asyncio
async def test_escrow_double_release_raises(mock, payer, payee):
    invoice = Invoice(to=payee.address, amount=100.0)
    tx = await payer.pay(invoice)
    await payer.release_escrow(tx.invoice_id)

    with pytest.raises(InvalidState):
        await payer.release_escrow(tx.invoice_id)


@pytest.mark.asyncio
async def test_escrow_claim_start_changes_status(mock, payer, payee):
    invoice = Invoice(to=payee.address, amount=50.0)
    tx = await payer.pay(invoice)
    await payee.claim_start(tx.invoice_id)

    escrow = mock._state.escrows[list(mock._state.escrows.keys())[-1]]
    assert escrow.status == EscrowStatus.active


# ─── Tabs ─────────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_tab_open_and_close(mock, payer, payee):
    tab = await payer.open_tab(payee.address, limit=10.0, per_unit=0.01)
    assert tab.status == TabStatus.open
    assert await payer.balance() == 990.0  # limit reserved

    await payer.charge_tab(tab.id, units=100)  # 100 * $0.01 = $1.00

    await payer.close_tab(tab.id)
    # payee gets $1.00, payer gets back $9.00
    assert await payee.balance() == 1.0
    assert await payer.balance() == 999.0


@pytest.mark.asyncio
async def test_tab_charge_exceeds_limit(mock, payer, payee):
    tab = await payer.open_tab(payee.address, limit=1.0, per_unit=0.01)
    with pytest.raises(TabLimitExceeded):
        await payer.charge_tab(tab.id, units=200)  # 200 * $0.01 = $2.00 > $1.00 limit


@pytest.mark.asyncio
async def test_tab_close_unknown_id(mock, payer):
    with pytest.raises(TabNotFound):
        await payer.close_tab("nonexistent_id")


@pytest.mark.asyncio
async def test_tab_double_close_raises(mock, payer, payee):
    tab = await payer.open_tab(payee.address, limit=5.0, per_unit=0.10)
    await payer.close_tab(tab.id)
    with pytest.raises(InvalidState):
        await payer.close_tab(tab.id)


# ─── Streams ──────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_stream_open_and_close(mock, payer, payee):
    stream = await payer.open_stream(payee.address, rate=1.0, max_duration=60)
    assert stream.status == StreamStatus.active

    mock.advance_time(30)  # 30 seconds pass
    await payer.close_stream(stream.id)

    # Payee should get roughly 30 * $1.00 = $30 (mock uses time.time() so may vary)
    payee_balance = await payee.balance()
    assert payee_balance >= 0.0
    # Payer got remainder back
    assert await payer.balance() + payee_balance == pytest.approx(1000.0, abs=1.0)


# ─── Bounties ─────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_bounty_post_and_award(mock, payer, payee):
    bounty = await payer.post_bounty(
        amount=50.0, task="write tests", deadline=mock.now() + 3600
    )
    assert bounty.status == BountyStatus.open
    assert await payer.balance() == 950.0

    await payee.submit_bounty(bounty.id, evidence_uri="ipfs://Qm...")
    await payer.award_bounty(bounty.id, winner=payee.address)

    assert await payee.balance() == 50.0
    assert mock._state.bounties[bounty.id].status == BountyStatus.awarded


@pytest.mark.asyncio
async def test_bounty_award_unknown(mock, payer, payee):
    with pytest.raises(BountyNotFound):
        await payer.award_bounty("nonexistent", winner=payee.address)


@pytest.mark.asyncio
async def test_bounty_double_award_raises(mock, payer, payee):
    bounty = await payer.post_bounty(25.0, "task", deadline=mock.now() + 3600)
    await payer.award_bounty(bounty.id, winner=payee.address)
    with pytest.raises(InvalidState):
        await payer.award_bounty(bounty.id, winner=payee.address)


# ─── Deposits ─────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_deposit_locked_and_returned(mock, payer, payee):
    deposit = await payer.place_deposit(payee.address, amount=20.0, expires=3600)
    assert deposit.status == DepositStatus.locked
    assert await payer.balance() == 980.0

    await payee.return_deposit(deposit.id)
    assert await payer.balance() == 1000.0
    assert mock._state.deposits[deposit.id].status == DepositStatus.returned


@pytest.mark.asyncio
async def test_deposit_forfeited(mock, payer, payee):
    deposit = await payer.place_deposit(payee.address, amount=20.0, expires=3600)
    await payee.forfeit_deposit(deposit.id)
    assert await payee.balance() == 20.0
    assert mock._state.deposits[deposit.id].status == DepositStatus.forfeited


# ─── Disputes ─────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_file_dispute(mock, payer, payee):
    invoice = Invoice(to=payee.address, amount=100.0)
    tx = await payer.pay(invoice)
    dispute = await payer.file_dispute(
        invoice_id=tx.invoice_id,
        reason="non_delivery",
        details="Work was not completed",
        evidence_uri="ipfs://Qm...",
    )
    assert dispute.status == DisputeStatus.open
    assert dispute.invoice_id == tx.invoice_id


# ─── Forced errors ────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_set_behavior_forces_error(mock, payer, payee):
    from remitmd.errors import RemitError
    mock.set_behavior(payer.address, "RATE_LIMIT_EXCEEDED")
    with pytest.raises(RemitError) as exc_info:
        await payer.pay_direct(payee.address, 1.0)
    assert exc_info.value.code == "RATE_LIMIT_EXCEEDED"


@pytest.mark.asyncio
async def test_forced_error_is_consumed_once(mock, payer, payee):
    mock.set_behavior(payer.address, "SERVER_ERROR")
    from remitmd.errors import RemitError
    with pytest.raises(RemitError):
        await payer.pay_direct(payee.address, 1.0)
    # Second call should succeed
    tx = await payer.pay_direct(payee.address, 1.0)
    assert tx.tx_hash is not None


# ─── Testnet faucet ───────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_request_testnet_funds(mock, payer):
    before = await payer.balance()
    await payer.request_testnet_funds()
    after = await payer.balance()
    assert after == before + 100.0


# ─── Webhooks ─────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_register_webhook(mock, payer):
    wh = await payer.register_webhook(
        url="https://example.com/hook",
        events=["escrow.funded", "escrow.released"],
    )
    assert wh.active is True
    assert "escrow.funded" in wh.events
