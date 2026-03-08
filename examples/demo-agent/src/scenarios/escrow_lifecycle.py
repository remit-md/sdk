"""
Escrow Lifecycle Scenario

Demonstrates fixed-price escrow payment using the Code Review demo service.

Steps:
  1. Discover code review service via /.well-known/remit.json
  2. Create an invoice for $2.00 code review
  3. Fund the escrow on-chain
  4. Submit code to the review service (triggers claim-start + evidence)
  5. Poll until review is complete
  6. Verify the review evidence
  7. Release the escrow
  8. Verify payee received funds minus fee
"""

from __future__ import annotations

import asyncio
import os
import time
from typing import Any

import httpx

CODE_REVIEW_URL = os.environ.get("CODE_REVIEW_URL", "http://localhost:3003")
REMITMD_API_URL = os.environ.get("REMITMD_API_URL", "http://localhost:8080")
AGENT_KEY = os.environ.get(
    "REMITMD_KEY",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
)

SAMPLE_CODE = """
async function fetchUserData(userId) {
  var response = await fetch('/api/users/' + userId);
  // TODO: handle errors
  const data = response.json();
  console.log('User data:', data);
  return data;
}

async function processUser(userId) {
  const user = fetchUserData(userId);  // missing await
  return user.name.toUpperCase();
}
"""


async def run() -> None:
    async with httpx.AsyncClient(timeout=60) as client:
        # -- Step 1: Discover service ------------------------------------------
        print("→ Discovering code review service...")
        manifest_resp = await client.get(f"{CODE_REVIEW_URL}/.well-known/remit.json")
        manifest_resp.raise_for_status()
        manifest: dict[str, Any] = manifest_resp.json()

        service = manifest["services"][0]
        payee = manifest["agent"]
        price_usd = service["price_usd"]
        print(f"  Found: {manifest['name']} — payee={payee}, price=${price_usd}")

        # -- Step 2: Create invoice --------------------------------------------
        print(f"→ Creating invoice for ${price_usd} code review...")
        invoice_resp = await client.post(
            f"{REMITMD_API_URL}/api/v0/invoices",
            json={
                "payee": payee,
                "amount_usd": price_usd,
                "description": "Code review — async JavaScript patterns",
                "payment_type": "escrow",
            },
            headers={"X-RemitMD-Key": AGENT_KEY},
        )
        invoice_resp.raise_for_status()
        invoice: dict[str, Any] = invoice_resp.json()
        invoice_id = invoice["invoice_id"]
        print(f"  Invoice created: {invoice_id}")

        # -- Step 3: Fund escrow -----------------------------------------------
        print("→ Funding escrow...")
        escrow_resp = await client.post(
            f"{REMITMD_API_URL}/api/v0/escrows",
            json={"invoice_id": invoice_id},
            headers={"X-RemitMD-Key": AGENT_KEY},
        )
        escrow_resp.raise_for_status()
        escrow: dict[str, Any] = escrow_resp.json()
        escrow_id = escrow["escrow_id"]
        print(f"  Escrow funded: {escrow_id}, amount=${escrow.get('amount_usd', price_usd)}")

        # -- Step 4: Submit code for review ------------------------------------
        print("→ Submitting code for review...")
        review_resp = await client.post(
            f"{CODE_REVIEW_URL}/v1/review",
            json={"escrowId": escrow_id, "code": SAMPLE_CODE},
        )
        # 202 Accepted is expected — review is async
        assert review_resp.status_code in (200, 202), (
            f"Unexpected status {review_resp.status_code}: {review_resp.text}"
        )
        print(f"  Review submitted (HTTP {review_resp.status_code}) — polling for completion...")

        # -- Step 5: Poll until complete ---------------------------------------
        max_wait_secs = 30
        poll_interval = 1
        elapsed = 0
        review_result: dict[str, Any] | None = None

        while elapsed < max_wait_secs:
            await asyncio.sleep(poll_interval)
            elapsed += poll_interval

            status_resp = await client.get(f"{CODE_REVIEW_URL}/v1/review/{escrow_id}")
            if status_resp.status_code == 404:
                continue  # job not yet visible
            status_resp.raise_for_status()
            job: dict[str, Any] = status_resp.json()

            if job["status"] == "complete":
                review_result = job["review"]
                print(f"  Review complete after {elapsed}s")
                break
            elif job["status"] == "failed":
                raise RuntimeError(f"Review failed: {job.get('error', 'unknown')}")
            else:
                print(f"  Still in progress ({elapsed}s elapsed)...")

        assert review_result is not None, f"Review did not complete within {max_wait_secs}s"

        # -- Step 6: Verify review evidence ------------------------------------
        print("→ Verifying review...")
        score = review_result["score"]
        issues = review_result["issues"]
        evidence_hash = review_result["evidence_hash"]
        print(f"  Score: {score}/100, Issues: {len(issues)}, Evidence: {evidence_hash[:16]}...")

        # Our sample code has known issues — verify at least 2 were found
        assert len(issues) >= 2, f"Expected ≥2 issues in sample code, got {len(issues)}"
        print(f"  Issues found: {[i['severity'] + ': ' + i['message'][:40] for i in issues]}")

        # -- Step 7: Release escrow --------------------------------------------
        print("→ Releasing escrow...")
        release_resp = await client.post(
            f"{REMITMD_API_URL}/api/v0/escrows/{escrow_id}/release",
            headers={"X-RemitMD-Key": AGENT_KEY},
        )
        release_resp.raise_for_status()
        release_data: dict[str, Any] = release_resp.json()

        # -- Step 8: Verify payee received funds -------------------------------
        payout_usd = float(release_data.get("payout_usd", 0))
        fee_usd = float(release_data.get("fee_usd", 0))
        expected_payout = price_usd - fee_usd
        tolerance = 0.01

        assert abs(payout_usd - expected_payout) < tolerance, (
            f"Expected payout ~${expected_payout:.2f}, got ${payout_usd:.2f}"
        )
        print(
            f"  Released: ${price_usd:.2f} total, ${fee_usd:.4f} fee, "
            f"${payout_usd:.2f} to payee ✓"
        )
