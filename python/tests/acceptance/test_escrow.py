"""
Python SDK acceptance: Escrow lifecycle via wallet.pay(), claim_start(), release_escrow().
"""

import time

import pytest

from remitmd.models.invoice import Invoice

from .conftest import (
    assert_balance_change,
    create_wallet,
    fund_wallet,
    get_fee_wallet_balance,
    get_usdc_balance,
    wait_for_balance_change,
)

pytestmark = pytest.mark.timeout(180)


@pytest.mark.asyncio
async def test_escrow_lifecycle() -> None:
    agent = await create_wallet()
    provider = await create_wallet()
    await fund_wallet(agent, 100)

    amount = 5.0
    fee = amount * 0.01
    provider_receives = amount - fee

    agent_before = await get_usdc_balance(agent.address)
    provider_before = await get_usdc_balance(provider.address)
    fee_before = await get_fee_wallet_balance()

    # Get escrow contract for permit
    contracts = await agent.get_contracts()
    escrow_contract = contracts["escrow"]

    # Sign permit for escrow
    deadline = int(time.time()) + 3600
    raw_amount = int((amount + 1) * 1_000_000)
    permit = await agent.sign_usdc_permit(
        spender=escrow_contract,
        value=raw_amount,
        deadline=deadline,
        nonce=0,
    )

    # Create and fund escrow
    invoice = Invoice(to=provider.address, amount=amount, memo="python-escrow-test")
    escrow = await agent.pay(invoice, permit=permit)
    escrow_id = escrow.invoice_id
    assert escrow_id is not None, "escrow should have an id"

    # Wait for on-chain lock
    await wait_for_balance_change(agent.address, agent_before)

    # Provider claims
    await provider.claim_start(escrow_id)
    import asyncio

    await asyncio.sleep(5)

    # Agent releases
    await agent.release_escrow(escrow_id)

    # Verify balances
    provider_after = await wait_for_balance_change(provider.address, provider_before)
    fee_after = await get_fee_wallet_balance()
    agent_after = await get_usdc_balance(agent.address)

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change("provider", provider_before, provider_after, provider_receives)
    assert_balance_change("fee wallet", fee_before, fee_after, fee)
