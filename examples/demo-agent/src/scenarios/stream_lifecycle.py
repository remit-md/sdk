"""
Stream Lifecycle Scenario

Demonstrates token streaming payments.

Steps:
  1. Open a stream to a payee at $0.001/second, max $0.10 total
  2. Wait 30 seconds (expected accrual: ~$0.030)
  3. Payee withdraws accrued funds
  4. Close the stream
  5. Verify amounts (accrued ≈ $0.030, refund ≈ $0.070)
"""

from __future__ import annotations

import asyncio
import os
import time
from typing import Any

import httpx

REMITMD_API_URL = os.environ.get("REMITMD_API_URL", "http://localhost:8080")
AGENT_KEY = os.environ.get(
    "REMITMD_KEY",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
)

# Use a second Anvil account as the payee
PAYEE_ADDRESS = os.environ.get("STREAM_PAYEE", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8")

RATE_PER_SECOND_USD = 0.001
STREAM_DURATION_SECS = 30
MAX_USD = 0.10
EXPECTED_ACCRUAL_USD = RATE_PER_SECOND_USD * STREAM_DURATION_SECS  # $0.030


async def run() -> None:
    async with httpx.AsyncClient(timeout=60) as client:
        # -- Step 1: Open stream -----------------------------------------------
        print(f"→ Opening stream: ${RATE_PER_SECOND_USD}/sec to {PAYEE_ADDRESS[:12]}...")
        stream_resp = await client.post(
            f"{REMITMD_API_URL}/api/v0/streams",
            json={
                "payee": PAYEE_ADDRESS,
                "rate_per_second_usd": RATE_PER_SECOND_USD,
                "max_usd": MAX_USD,
                "description": "Demo: continuous service payment stream",
            },
            headers={"X-RemitMD-Key": AGENT_KEY},
        )
        stream_resp.raise_for_status()
        stream: dict[str, Any] = stream_resp.json()
        stream_id = stream["stream_id"]
        print(f"  Stream opened: {stream_id}")

        # -- Step 2: Wait for accrual -----------------------------------------
        print(f"→ Waiting {STREAM_DURATION_SECS}s for funds to accrue...")
        await asyncio.sleep(STREAM_DURATION_SECS)

        # -- Step 3: Check accrued amount -------------------------------------
        status_resp = await client.get(
            f"{REMITMD_API_URL}/api/v0/streams/{stream_id}",
            headers={"X-RemitMD-Key": AGENT_KEY},
        )
        status_resp.raise_for_status()
        stream_status: dict[str, Any] = status_resp.json()

        accrued_usd = float(stream_status.get("accrued_usd", 0))
        tolerance = 0.005  # 5ms timing tolerance
        print(f"  Accrued: ${accrued_usd:.4f} (expected ~${EXPECTED_ACCRUAL_USD:.3f})")
        assert abs(accrued_usd - EXPECTED_ACCRUAL_USD) < tolerance + RATE_PER_SECOND_USD, (
            f"Accrual mismatch: expected ~${EXPECTED_ACCRUAL_USD:.3f}, got ${accrued_usd:.4f}"
        )

        # -- Step 4: Payee withdraws -------------------------------------------
        print("→ Payee withdrawing accrued funds...")
        withdraw_resp = await client.post(
            f"{REMITMD_API_URL}/api/v0/streams/{stream_id}/withdraw",
            headers={"X-RemitMD-Key": AGENT_KEY},  # In prod: payee's key
        )
        withdraw_resp.raise_for_status()
        withdraw_data: dict[str, Any] = withdraw_resp.json()
        withdrawn_usd = float(withdraw_data.get("withdrawn_usd", 0))
        print(f"  Withdrew: ${withdrawn_usd:.4f} ✓")

        # -- Step 5: Close stream ----------------------------------------------
        print("→ Closing stream...")
        close_resp = await client.post(
            f"{REMITMD_API_URL}/api/v0/streams/{stream_id}/close",
            headers={"X-RemitMD-Key": AGENT_KEY},
        )
        close_resp.raise_for_status()
        close_data: dict[str, Any] = close_resp.json()

        # -- Step 6: Verify amounts --------------------------------------------
        refund_usd = float(close_data.get("refund_usd", 0))
        expected_refund = MAX_USD - accrued_usd
        assert abs(refund_usd - expected_refund) < tolerance + RATE_PER_SECOND_USD, (
            f"Refund mismatch: expected ~${expected_refund:.3f}, got ${refund_usd:.4f}"
        )
        print(
            f"  Stream closed. Accrued: ${accrued_usd:.4f}, "
            f"Refund: ${refund_usd:.4f} (of ${MAX_USD:.2f} max) ✓"
        )
