"""
Python SDK acceptance: Bounty lifecycle via wallet.post_bounty(), submit_bounty(), award_bounty().
Verifies SDK permit signing + full bounty lifecycle with balance assertions.
"""

import asyncio
import time

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
async def test_bounty_lifecycle() -> None:
    poster = await create_wallet()
    provider = await create_wallet()
    await fund_wallet(poster, 100)

    amount = 5.0
    fee = amount * 0.01  # 1% = $0.05
    provider_receives = amount - fee  # $4.95

    poster_before = await get_usdc_balance(poster.address)
    provider_before = await get_usdc_balance(provider.address)
    # Step 1: Post bounty with permit for Bounty contract
    contracts = await poster.get_contracts()
    bounty_contract = contracts["bounty"]

    deadline_ts = int(time.time()) + 3600
    raw_amount = int((amount + 1) * 1_000_000)
    permit = await poster.sign_usdc_permit(
        spender=bounty_contract,
        value=raw_amount,
        deadline=deadline_ts,
        nonce=0,
    )

    bounty = await poster.post_bounty(
        amount=amount,
        task="python-bounty-acceptance-test",
        deadline=deadline_ts,
        permit=permit,
    )
    assert bounty.id, "bounty should have an id"
    if hasattr(bounty, "tx_hash") and bounty.tx_hash:
        log_tx("bounty", "post", bounty.tx_hash)

    # Wait for on-chain bounty creation (poster USDC locked in Bounty contract)
    await wait_for_balance_change(poster.address, poster_before)

    # Step 2: Provider submits evidence
    evidence_hash = "0x" + "ab" * 32
    submission = await provider.submit_bounty(
        bounty.id,
        evidence_hash=evidence_hash,
    )
    if submission.tx_hash:
        log_tx("bounty", "submit", submission.tx_hash)
    else:
        print("[ACCEPTANCE] bounty submit: no tx_hash (off-chain submission)")

    # Wait for submission to transition bounty to "claimed" status
    # The server must index the on-chain submit event before award is possible
    for _ in range(10):
        await asyncio.sleep(3)
        try:
            awarded = await poster.award_bounty(bounty.id, submission_id=1)
            break
        except Exception as e:
            print(f"[ACCEPTANCE] award not ready yet: {e}")
    else:
        # Final attempt — let it raise
        awarded = await poster.award_bounty(bounty.id, submission_id=1)
    assert awarded.status == "awarded", f"bounty should be awarded, got {awarded.status}"
    if hasattr(awarded, "tx_hash") and awarded.tx_hash:
        log_tx("bounty", "award", awarded.tx_hash)

    # Verify balances
    provider_after = await wait_for_balance_change(provider.address, provider_before)
    poster_after = await get_usdc_balance(poster.address)

    # Poster: lost $5 (bounty amount)
    assert_balance_change("poster", poster_before, poster_after, -amount)
    # Provider: received $5 minus 1% fee = $4.95
    assert_balance_change("provider", provider_before, provider_after, provider_receives)
