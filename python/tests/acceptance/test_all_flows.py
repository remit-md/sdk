"""
Python SDK acceptance: All 9 payment flows with 2 shared wallets.

Creates agent (payer) + provider (payee) wallets once, mints 100 USDC
to agent, then runs all 9 flows sequentially with small amounts.

Flows: direct, escrow, tab, stream, bounty, deposit, x402, AP2 discovery, AP2 payment.
"""

import asyncio
import base64
import json
import time

import pytest

from remitmd.a2a import A2AClient, AgentCard
from remitmd.models.invoice import Invoice

from .conftest import (
    API_URL,
    assert_balance_change,
    create_wallet,
    fund_wallet,
    get_usdc_balance,
    log_tx,
    wait_for_balance_change,
)

pytestmark = pytest.mark.timeout(600)

# ── Shared fixtures ──────────────────────────────────────────────────────────


@pytest.fixture(scope="module")
def event_loop():
    loop = asyncio.new_event_loop()
    yield loop
    loop.close()


@pytest.fixture(scope="module")
async def wallets():
    """Create 2 wallets and fund agent with 100 USDC."""
    agent = await create_wallet()
    provider = await create_wallet()
    await fund_wallet(agent, 100)
    return agent, provider


# ── Flow 1: Direct ───────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_01_direct(wallets) -> None:
    agent, provider = wallets
    amount = 1.0

    agent_before = await get_usdc_balance(agent.address)
    provider_before = await get_usdc_balance(provider.address)

    permit = await agent.sign_permit("direct", amount)
    tx = await agent.pay_direct(
        to=provider.address,
        amount=amount,
        memo="acceptance-direct",
        permit=permit,
    )

    assert tx.tx_hash and tx.tx_hash.startswith("0x")
    log_tx("direct", f"{amount} USDC {agent.address}->{provider.address}", tx.tx_hash)

    agent_after = await wait_for_balance_change(agent.address, agent_before)
    provider_after = await get_usdc_balance(provider.address)

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change(
        "provider",
        provider_before,
        provider_after,
        amount * 0.99,
    )


# ── Flow 2: Escrow ──────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_02_escrow(wallets) -> None:
    agent, provider = wallets
    amount = 2.0

    agent_before = await get_usdc_balance(agent.address)
    provider_before = await get_usdc_balance(provider.address)

    permit = await agent.sign_permit("escrow", amount)
    invoice = Invoice(to=provider.address, amount=amount, memo="acceptance-escrow")
    escrow = await agent.pay(invoice, permit=permit)
    escrow_id = escrow.invoice_id
    assert escrow_id
    if escrow.tx_hash:
        log_tx("escrow", f"fund {amount} USDC", escrow.tx_hash)

    await wait_for_balance_change(agent.address, agent_before)

    claim = await provider.claim_start(escrow_id)
    if claim.tx_hash:
        log_tx("escrow", "claimStart", claim.tx_hash)
    await asyncio.sleep(5)

    release = await agent.release_escrow(escrow_id)
    if release.tx_hash:
        log_tx("escrow", "release", release.tx_hash)

    provider_after = await wait_for_balance_change(
        provider.address,
        provider_before,
    )
    agent_after = await get_usdc_balance(agent.address)

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change(
        "provider",
        provider_before,
        provider_after,
        amount * 0.99,
    )


# ── Flow 3: Tab ─────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_03_tab(wallets) -> None:
    agent, provider = wallets
    limit = 5.0
    charge_amount = 1.0
    charge_units = int(charge_amount * 1_000_000)

    agent_before = await get_usdc_balance(agent.address)
    provider_before = await get_usdc_balance(provider.address)

    contracts = await agent.get_contracts()
    tab_contract = contracts["tab"]

    permit = await agent.sign_permit("tab", limit)
    tab = await agent.open_tab(
        to=provider.address,
        limit=limit,
        per_unit=0.1,
        permit=permit,
    )
    assert tab.id
    if tab.tx_hash:
        log_tx("tab", f"open limit={limit}", tab.tx_hash)

    await wait_for_balance_change(agent.address, agent_before)

    call_count = 1
    charge_sig = await provider.sign_tab_charge(
        tab_contract=tab_contract,
        tab_id=tab.id,
        total_charged=charge_units,
        call_count=call_count,
    )
    charge = await provider.charge_tab(
        tab_id=tab.id,
        amount=charge_amount,
        cumulative=charge_amount,
        call_count=call_count,
        provider_sig=charge_sig,
    )
    assert charge.tab_id == tab.id

    close_sig = await provider.sign_tab_charge(
        tab_contract=tab_contract,
        tab_id=tab.id,
        total_charged=charge_units,
        call_count=call_count,
    )
    closed = await agent.close_tab(
        tab_id=tab.id,
        final_amount=charge_amount,
        provider_sig=close_sig,
    )
    assert closed.tx_hash and closed.tx_hash.startswith("0x")
    log_tx("tab", "close", closed.tx_hash)

    provider_after = await wait_for_balance_change(
        provider.address,
        provider_before,
    )
    agent_after = await get_usdc_balance(agent.address)

    assert_balance_change("agent", agent_before, agent_after, -charge_amount)
    assert_balance_change(
        "provider",
        provider_before,
        provider_after,
        charge_amount * 0.99,
    )


# ── Flow 4: Stream ──────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_04_stream(wallets) -> None:
    agent, provider = wallets
    rate = 0.1  # $0.10/s
    max_total = 2.0

    agent_before = await get_usdc_balance(agent.address)
    provider_before = await get_usdc_balance(provider.address)

    permit = await agent.sign_permit("stream", max_total)
    stream = await agent.open_stream(
        to=provider.address,
        rate=rate,
        max_total=max_total,
        permit=permit,
    )
    assert stream.id
    if stream.tx_hash:
        log_tx("stream", f"open rate={rate}/s max={max_total}", stream.tx_hash)

    await wait_for_balance_change(agent.address, agent_before)
    await asyncio.sleep(5)

    closed = await agent.close_stream(stream.id)
    assert closed.status == "closed"
    if closed.tx_hash:
        log_tx("stream", "close", closed.tx_hash)

    provider_after = await wait_for_balance_change(
        provider.address,
        provider_before,
    )
    agent_after = await get_usdc_balance(agent.address)

    agent_loss = agent_before - agent_after
    assert agent_loss > 0.05, f"agent should lose money, loss={agent_loss}"
    assert agent_loss <= max_total + 0.01

    provider_gain = provider_after - provider_before
    assert provider_gain > 0.04, f"provider should gain, gain={provider_gain}"


# ── Flow 5: Bounty ──────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_05_bounty(wallets) -> None:
    agent, provider = wallets
    amount = 2.0
    deadline_ts = int(time.time()) + 3600

    agent_before = await get_usdc_balance(agent.address)
    provider_before = await get_usdc_balance(provider.address)

    permit = await agent.sign_permit("bounty", amount)
    bounty = await agent.post_bounty(
        amount=amount,
        task="acceptance-bounty",
        deadline=deadline_ts,
        permit=permit,
    )
    assert bounty.id
    if bounty.tx_hash:
        log_tx("bounty", f"post {amount} USDC", bounty.tx_hash)

    await wait_for_balance_change(agent.address, agent_before)

    evidence = "0x" + "ab" * 32
    await provider.submit_bounty(bounty.id, evidence_hash=evidence)
    print(f"[ACCEPTANCE] bounty | submit | id={bounty.id}")

    # Retry award (Ponder indexer lag — C7.10 fix)
    awarded = None
    for attempt in range(15):
        await asyncio.sleep(3)
        try:
            awarded = await agent.award_bounty(bounty.id, submission_id=1)
            break
        except Exception as e:
            if attempt < 14:
                print(f"[ACCEPTANCE] bounty award retry {attempt + 1}: {e}")
            else:
                raise
    assert awarded and awarded.status == "awarded"
    if awarded.tx_hash:
        log_tx("bounty", "award", awarded.tx_hash)

    provider_after = await wait_for_balance_change(
        provider.address,
        provider_before,
    )
    agent_after = await get_usdc_balance(agent.address)

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change(
        "provider",
        provider_before,
        provider_after,
        amount * 0.99,
    )


# ── Flow 6: Deposit ─────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_06_deposit(wallets) -> None:
    agent, provider = wallets
    amount = 2.0

    agent_before = await get_usdc_balance(agent.address)

    permit = await agent.sign_permit("deposit", amount)
    deposit = await agent.place_deposit(
        to=provider.address,
        amount=amount,
        expires=3600,
        permit=permit,
    )
    assert deposit.id
    if deposit.tx_hash:
        log_tx("deposit", f"place {amount} USDC", deposit.tx_hash)

    agent_mid = await wait_for_balance_change(agent.address, agent_before)
    assert_balance_change("agent locked", agent_before, agent_mid, -amount)

    returned = await provider.return_deposit(deposit.id)
    assert returned.status == "returned"
    if returned.tx_hash:
        log_tx("deposit", "return", returned.tx_hash)

    agent_after = await wait_for_balance_change(agent.address, agent_mid)
    assert_balance_change("agent refund", agent_before, agent_after, 0)


# ── Flow 7: x402 (via /x402/prepare — no local HTTP server) ─────────────────


@pytest.mark.asyncio
async def test_07_x402_prepare(wallets) -> None:
    agent, _provider = wallets

    contracts = await agent.get_contracts()
    payment_required = {
        "scheme": "exact",
        "network": "eip155:84532",
        "amount": "100000",
        "asset": contracts["usdc"],
        "payTo": contracts["router"],
        "maxTimeoutSeconds": 60,
    }
    encoded = base64.b64encode(
        json.dumps(payment_required).encode(),
    ).decode()

    # Call /x402/prepare to get the EIP-3009 hash
    from remitmd._http import AuthenticatedClient  # noqa: PLC0415

    auth = AuthenticatedClient(
        base_url=API_URL,
        signer=agent._signer,
        chain_id=agent._http._chain_id,
        verifying_contract=agent._http._verifying_contract,
    )
    try:
        data = await auth.post(
            "/api/v1/x402/prepare",
            {"payment_required": encoded, "payer": agent.address},
        )
    finally:
        await auth.close()

    assert "hash" in data, f"x402/prepare missing hash: {data}"
    assert data["hash"].startswith("0x")
    assert len(data["hash"]) == 66  # 0x + 64 hex chars
    assert "from" in data
    assert "to" in data
    assert "value" in data

    print(
        f"[ACCEPTANCE] x402 | prepare | hash={data['hash'][:18]}... | from={data['from'][:10]}..."
    )


# ── Flow 8: AP2 Discovery ───────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_08_ap2_discovery(wallets) -> None:
    _agent, _provider = wallets

    card = await AgentCard.discover(API_URL)
    assert card.name, "agent card should have a name"
    assert card.url, "agent card should have a URL"
    assert len(card.skills) > 0, "agent card should have skills"
    assert card.x402, "agent card should have x402 config"

    print(
        f"[ACCEPTANCE] ap2-discovery | name={card.name}"
        f" | skills={len(card.skills)}"
        f" | x402={bool(card.x402)}"
    )


# ── Flow 9: AP2 Payment ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_09_ap2_payment(wallets) -> None:
    agent, provider = wallets
    amount = 1.0

    agent_before = await get_usdc_balance(agent.address)
    provider_before = await get_usdc_balance(provider.address)

    card = await AgentCard.discover(API_URL)
    permit = await agent.sign_permit("direct", amount)

    async with A2AClient.from_wallet(card, agent) as a2a:
        task = await a2a.send(
            to=provider.address,
            amount=amount,
            memo="acceptance-ap2",
            permit=permit,
        )

    assert task.succeeded, f"A2A task failed: state={task.state}, error={task.error}"
    tx_hash = task.tx_hash
    assert tx_hash and tx_hash.startswith("0x")
    log_tx("ap2-payment", f"{amount} USDC via A2A", tx_hash)

    agent_after = await wait_for_balance_change(agent.address, agent_before)
    provider_after = await get_usdc_balance(provider.address)

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change(
        "provider",
        provider_before,
        provider_after,
        amount * 0.99,
    )
