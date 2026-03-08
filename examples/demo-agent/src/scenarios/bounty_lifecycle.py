"""
Bounty Lifecycle Scenario

Demonstrates task bounty payments.

Steps:
  1. Post a $5.00 bounty: "Find the best gas price API endpoint"
  2. A second agent discovers and submits a solution
  3. Demo agent reviews the submission and awards the bounty
  4. Verify winner received funds minus protocol fee
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

# Solver agent — a second demo wallet (Anvil key #4)
SOLVER_KEY = os.environ.get(
    "SOLVER_KEY",
    "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926b",
)
SOLVER_ADDRESS = os.environ.get("SOLVER_ADDRESS", "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc")

BOUNTY_USD = 5.00
DEADLINE_SECS = 3600  # 1 hour


async def run() -> None:
    async with httpx.AsyncClient(timeout=60) as client:
        # -- Step 1: Post bounty -----------------------------------------------
        print(f"→ Posting ${BOUNTY_USD} bounty...")
        bounty_resp = await client.post(
            f"{REMITMD_API_URL}/api/v0/bounties",
            json={
                "title": "Find the cheapest gas price API",
                "description": (
                    "Research and return the URL of the best free gas price API for Base chain. "
                    "Include response format, rate limits, and accuracy notes."
                ),
                "reward_usd": BOUNTY_USD,
                "deadline_secs": DEADLINE_SECS,
                "max_submissions": 5,
            },
            headers={"X-RemitMD-Key": AGENT_KEY},
        )
        bounty_resp.raise_for_status()
        bounty: dict[str, Any] = bounty_resp.json()
        bounty_id = bounty["bounty_id"]
        print(f"  Bounty posted: {bounty_id}")

        # -- Step 2: Solver discovers and submits solution --------------------
        print("→ Solver agent submitting solution...")
        submission_resp = await client.post(
            f"{REMITMD_API_URL}/api/v0/bounties/{bounty_id}/submit",
            json={
                "solution": (
                    "Best option: https://api.blocknative.com/gasprices/blockprices\n"
                    "Response: JSON with {baseFeePerGas, estimatedPrices: [{confidence, price}]}\n"
                    "Rate limit: 2000 req/day free tier\n"
                    "Accuracy: real-time mempool data, updates every 5s\n"
                    "Alternative: https://gas.api.infura.io — requires API key"
                ),
                "submitter": SOLVER_ADDRESS,
            },
            headers={"X-RemitMD-Key": SOLVER_KEY},
        )
        submission_resp.raise_for_status()
        submission: dict[str, Any] = submission_resp.json()
        submission_id = submission["submission_id"]
        print(f"  Submission received: {submission_id}")

        # Give the API a moment to process
        await asyncio.sleep(0.5)

        # -- Step 3: Review submission -----------------------------------------
        print("→ Reviewing submission...")
        submissions_resp = await client.get(
            f"{REMITMD_API_URL}/api/v0/bounties/{bounty_id}/submissions",
            headers={"X-RemitMD-Key": AGENT_KEY},
        )
        submissions_resp.raise_for_status()
        submissions_data: dict[str, Any] = submissions_resp.json()
        submissions = submissions_data.get("submissions", [])

        assert len(submissions) >= 1, f"Expected at least 1 submission, got {len(submissions)}"
        print(f"  Found {len(submissions)} submission(s). Awarding best...")

        # -- Step 4: Award bounty to solver ------------------------------------
        print("→ Awarding bounty...")
        award_resp = await client.post(
            f"{REMITMD_API_URL}/api/v0/bounties/{bounty_id}/award",
            json={
                "submission_id": submission_id,
                "feedback": "Excellent research. Blocknative API is the best free option for Base.",
            },
            headers={"X-RemitMD-Key": AGENT_KEY},
        )
        award_resp.raise_for_status()
        award_data: dict[str, Any] = award_resp.json()

        # -- Step 5: Verify payout --------------------------------------------
        payout_usd = float(award_data.get("payout_usd", 0))
        fee_usd = float(award_data.get("fee_usd", 0))
        expected_payout = BOUNTY_USD - fee_usd
        tolerance = 0.01

        assert payout_usd > 0, "Payout should be > 0"
        assert abs(payout_usd - expected_payout) < tolerance, (
            f"Expected payout ~${expected_payout:.2f}, got ${payout_usd:.2f}"
        )

        print(
            f"  Awarded: ${BOUNTY_USD:.2f} total, ${fee_usd:.4f} fee, "
            f"${payout_usd:.2f} to winner ✓"
        )
        print(f"  Winner: {SOLVER_ADDRESS}")
