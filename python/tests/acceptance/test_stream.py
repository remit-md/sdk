"""
Python SDK acceptance: Stream lifecycle via wallet.open_stream(), close_stream().
Verifies SDK permit signing + stream accrual + close with balance bounds.

Stream accrual is time-dependent (block timestamps). We use generous bounds
and conservation-of-funds checks rather than exact delta assertions.
"""

import asyncio
import time

import pytest

from .conftest import (
    create_wallet,
    fund_wallet,
    get_fee_wallet_balance,
    get_usdc_balance,
    log_tx,
    wait_for_balance_change,
)

pytestmark = pytest.mark.timeout(180)


@pytest.mark.asyncio
async def test_stream_lifecycle() -> None:
    agent = await create_wallet()
    provider = await create_wallet()
    await fund_wallet(agent, 100)

    rate_per_second = 0.1  # $0.10/s
    max_total = 5.0

    agent_before = await get_usdc_balance(agent.address)
    provider_before = await get_usdc_balance(provider.address)
    fee_before = await get_fee_wallet_balance()

    # Step 1: Open stream with permit for Stream contract
    contracts = await agent.get_contracts()
    stream_contract = contracts["stream"]

    deadline = int(time.time()) + 3600
    raw_amount = int((max_total + 1) * 1_000_000)
    permit = await agent.sign_usdc_permit(
        spender=stream_contract,
        value=raw_amount,
        deadline=deadline,
        nonce=0,
    )

    stream = await agent.open_stream(
        to=provider.address,
        rate=rate_per_second,
        max_total=max_total,
        permit=permit,
    )
    assert stream.id, "stream should have an id"
    if hasattr(stream, "tx_hash") and stream.tx_hash:
        log_tx("stream", "open", stream.tx_hash)

    # Wait for on-chain creation (agent locks maxTotal in Stream contract)
    await wait_for_balance_change(agent.address, agent_before)

    # Step 2: Wait for accrual (~5 seconds real time)
    await asyncio.sleep(5)

    # Step 3: Close stream (payer only)
    closed = await agent.close_stream(stream.id)
    assert closed.status == "closed", f"stream should be closed, got {closed.status}"
    if hasattr(closed, "tx_hash") and closed.tx_hash:
        log_tx("stream", "close", closed.tx_hash)

    # Wait for settlement (provider balance should increase)
    provider_after = await wait_for_balance_change(provider.address, provider_before)
    fee_after = await get_fee_wallet_balance()
    agent_after = await get_usdc_balance(agent.address)

    # Calculate actual changes
    agent_loss = agent_before - agent_after
    provider_gain = provider_after - provider_before
    fee_gain = fee_after - fee_before

    # Agent should have lost money (stream accrued), but <= maxTotal
    assert agent_loss > 0.05, f"agent should have lost money from streaming, got loss={agent_loss}"
    assert agent_loss <= max_total + 0.01, (
        f"agent loss should not exceed maxTotal (${max_total}), got loss={agent_loss}"
    )

    # Provider should have received payout (accrued minus 1% fee)
    assert provider_gain > 0.04, f"provider should have received payout, got gain={provider_gain}"

    # Fee wallet should not decrease
    assert fee_gain >= 0, f"fee wallet should not decrease, got change={fee_gain}"

    # Conservation of funds: agent loss ≈ provider gain + fee
    conservation_diff = abs(agent_loss - (provider_gain + fee_gain))
    assert conservation_diff < 0.01, (
        f"conservation violated: agent lost {agent_loss}, "
        f"provider+fee gained {provider_gain + fee_gain}, diff={conservation_diff}"
    )
