"""
Python SDK acceptance: Tab lifecycle via wallet.open_tab(), charge_tab(), close_tab().
Verifies SDK permit signing + tab charge EIP-712 signing + full lifecycle balances.
"""

import time

import pytest

from .conftest import (
    assert_balance_change,
    assert_fee_increase,
    create_wallet,
    fund_wallet,
    get_fee_wallet_balance,
    get_usdc_balance,
    log_tx,
    wait_for_balance_change,
)

pytestmark = pytest.mark.timeout(180)


@pytest.mark.asyncio
async def test_tab_lifecycle() -> None:
    agent = await create_wallet()
    provider = await create_wallet()
    await fund_wallet(agent, 100)

    limit = 10.0
    charge_amount = 2.0
    charge_units = int(charge_amount * 1_000_000)  # uint96 base units
    fee = charge_amount * 0.01  # 1% = $0.02
    provider_receives = charge_amount - fee  # $1.98

    agent_before = await get_usdc_balance(agent.address)
    provider_before = await get_usdc_balance(provider.address)
    fee_before = await get_fee_wallet_balance()

    # Step 1: Open tab (agent, with permit for Tab contract)
    contracts = await agent.get_contracts()
    tab_contract = contracts["tab"]

    deadline = int(time.time()) + 3600
    raw_amount = int((limit + 1) * 1_000_000)
    permit = await agent.sign_usdc_permit(
        spender=tab_contract,
        value=raw_amount,
        deadline=deadline,
        nonce=0,
    )

    tab = await agent.open_tab(
        to=provider.address,
        limit=limit,
        per_unit=0.1,
        permit=permit,
    )
    assert tab.id, "tab should have an id"
    if hasattr(tab, "tx_hash") and tab.tx_hash:
        log_tx("tab", "open", tab.tx_hash)

    # Wait for on-chain lock (agent USDC moves to Tab contract)
    await wait_for_balance_change(agent.address, agent_before)

    # Step 2: Provider charges $2 (off-chain with TabCharge EIP-712 sig)
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
    assert charge.tab_id == tab.id, "charge should reference the tab"
    if hasattr(charge, "tx_hash") and charge.tx_hash:
        log_tx("tab", "charge", charge.tx_hash)

    # Step 3: Close tab (agent, with provider's close signature on final state)
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
    assert closed.tx_hash and closed.tx_hash.startswith("0x"), (
        f"close should return tx hash, got: {closed.tx_hash}"
    )
    log_tx("tab", "close", closed.tx_hash)

    # Verify balances
    provider_after = await wait_for_balance_change(provider.address, provider_before)
    fee_after = await get_fee_wallet_balance()
    agent_after = await get_usdc_balance(agent.address)

    # Agent: locked $10, refunded $8, net change = -$2
    assert_balance_change("agent", agent_before, agent_after, -charge_amount)
    # Provider: received $2 minus 1% fee = $1.98
    assert_balance_change("provider", provider_before, provider_after, provider_receives)
    # Fee wallet: received at least 1% of $2 = $0.02
    assert_fee_increase("fee wallet", fee_before, fee_after, fee)
