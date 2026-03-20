"""
Python SDK acceptance: Direct payment via wallet.pay_direct().
Verifies SDK permit signing + payment works end-to-end on Base Sepolia.
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

pytestmark = pytest.mark.timeout(120)


@pytest.mark.asyncio
async def test_pay_direct_with_permit() -> None:
    agent = await create_wallet()
    provider = await create_wallet()
    await fund_wallet(agent, 100)

    amount = 1.0
    fee = 0.01
    provider_receives = amount - fee

    agent_before = await get_usdc_balance(agent.address)
    provider_before = await get_usdc_balance(provider.address)
    fee_before = await get_fee_wallet_balance()

    # Get router address for permit
    contracts = await agent.get_contracts()
    router = contracts["router"]

    # Sign EIP-2612 permit
    deadline = int(time.time()) + 3600
    raw_amount = int(2.0 * 1_000_000)  # permit for $2
    permit = await agent.sign_usdc_permit(
        spender=router,
        value=raw_amount,
        deadline=deadline,
        nonce=0,
    )

    # Pay
    tx = await agent.pay_direct(
        to=provider.address,
        amount=amount,
        memo="python-sdk-acceptance",
        permit=permit,
    )
    assert tx.tx_hash is not None and tx.tx_hash.startswith("0x"), f"bad tx_hash: {tx.tx_hash}"
    log_tx("direct", "pay", tx.tx_hash)

    agent_after = await wait_for_balance_change(agent.address, agent_before)
    provider_after = await get_usdc_balance(provider.address)
    fee_after = await get_fee_wallet_balance()

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change("provider", provider_before, provider_after, provider_receives)
    assert_fee_increase("fee wallet", fee_before, fee_after, fee)
