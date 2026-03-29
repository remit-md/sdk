"""
Python SDK acceptance: Deposit lifecycle via wallet.place_deposit(), return_deposit().
Verifies SDK permit signing + deposit lock/return with full refund (no fee).
"""

import pytest

from .conftest import (
    assert_balance_change,
    create_wallet,
    fund_wallet,
    get_usdc_balance,
    log_tx,
    wait_for_balance_change,
)

pytestmark = pytest.mark.timeout(180)


@pytest.mark.asyncio
async def test_deposit_lifecycle() -> None:
    agent = await create_wallet()
    provider = await create_wallet()
    await fund_wallet(agent, 100)

    amount = 5.0

    agent_before = await get_usdc_balance(agent.address)
    provider_before = await get_usdc_balance(provider.address)
    # Step 1: Place deposit with permit for Deposit contract
    permit = await agent.sign_permit("deposit", amount)

    deposit = await agent.place_deposit(
        to=provider.address,
        amount=amount,
        expires=3600,  # 1 hour
        permit=permit,
    )
    assert deposit.id, "deposit should have an id"
    if hasattr(deposit, "tx_hash") and deposit.tx_hash:
        log_tx("deposit", "place", deposit.tx_hash)

    # Wait for on-chain deposit lock
    agent_mid = await wait_for_balance_change(agent.address, agent_before)
    assert_balance_change("agent locked", agent_before, agent_mid, -amount)

    # Step 2: Provider returns the deposit
    returned = await provider.return_deposit(deposit.id)
    assert returned.status == "returned", f"deposit should be returned, got {returned.status}"
    if hasattr(returned, "tx_hash") and returned.tx_hash:
        log_tx("deposit", "return", returned.tx_hash)

    # Wait for return settlement (agent gets full refund)
    agent_after = await wait_for_balance_change(agent.address, agent_mid)
    provider_after = await get_usdc_balance(provider.address)

    # Agent: full refund - net change ≈ $0
    assert_balance_change("agent net", agent_before, agent_after, 0)
    # Provider: unchanged
    assert_balance_change("provider", provider_before, provider_after, 0)
