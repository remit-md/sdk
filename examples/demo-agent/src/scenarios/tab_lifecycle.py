"""
Tab Lifecycle Scenario

Demonstrates metered tab payment using the LLM API demo service.

Steps:
  1. Discover LLM API service via /.well-known/remit.json
  2. Open a $5.00 tab with the LLM API's wallet as payee
  3. Make 10 LLM API calls, each paying $0.003 via signed voucher
  4. Verify total charged matches expected ($0.030)
  5. Close the tab
  6. Verify unused funds are refunded
"""

from __future__ import annotations

import json
import os
import time
from typing import Any

import httpx

LLM_API_URL = os.environ.get("LLM_API_URL", "http://localhost:3001")
REMITMD_API_URL = os.environ.get("REMITMD_API_URL", "http://localhost:8080")
AGENT_KEY = os.environ.get(
    "REMITMD_KEY",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
)

TAB_LIMIT_USD = 5.00
CALLS_TO_MAKE = 10
PRICE_PER_CALL_USD = 0.003
EXPECTED_TOTAL_USD = CALLS_TO_MAKE * PRICE_PER_CALL_USD  # $0.030


async def run() -> None:
    async with httpx.AsyncClient(timeout=30) as client:
        # -- Step 1: Discover service ------------------------------------------
        print("→ Discovering LLM API service...")
        manifest_resp = await client.get(f"{LLM_API_URL}/.well-known/remit.json")
        manifest_resp.raise_for_status()
        manifest: dict[str, Any] = manifest_resp.json()

        payee = manifest["agent"]
        service = manifest["services"][0]
        print(f"  Found: {manifest['name']} — payee={payee}, price=${service['price_usd']}/call")

        # -- Step 2: Open tab --------------------------------------------------
        print(f"→ Opening tab: limit=${TAB_LIMIT_USD}, payee={payee}...")
        tab_resp = await client.post(
            f"{REMITMD_API_URL}/api/v0/tabs",
            json={
                "payee": payee,
                "limit_usd": TAB_LIMIT_USD,
                "price_per_call_usd": PRICE_PER_CALL_USD,
                "description": "Demo: LLM API metered tab",
            },
            headers={"X-RemitMD-Key": AGENT_KEY},
        )
        tab_resp.raise_for_status()
        tab: dict[str, Any] = tab_resp.json()
        tab_id = tab["tab_id"]
        print(f"  Tab opened: {tab_id}")

        # -- Step 3: Make API calls --------------------------------------------
        print(f"→ Making {CALLS_TO_MAKE} API calls...")
        successful_calls = 0

        for i in range(CALLS_TO_MAKE):
            # Get a signed voucher from the remit.md API
            voucher_resp = await client.post(
                f"{REMITMD_API_URL}/api/v0/tabs/{tab_id}/voucher",
                json={"payee": payee, "amount_usd": PRICE_PER_CALL_USD},
                headers={"X-RemitMD-Key": AGENT_KEY},
            )
            voucher_resp.raise_for_status()
            voucher = voucher_resp.json()

            # Call the LLM API with the voucher
            prompts = [
                "Explain distributed systems in one sentence",
                "What is the CAP theorem?",
                "How does USDC maintain its peg?",
                "What is an EVM L2 chain?",
                "Explain zero-knowledge proofs briefly",
                "What is a smart contract?",
                "How does escrow work?",
                "What is EIP-712?",
                "Explain blockchain finality",
                "What are metered API payments?",
            ]
            prompt = prompts[i % len(prompts)]

            llm_resp = await client.post(
                f"{LLM_API_URL}/v1/generate",
                json={"prompt": prompt},
                headers={"X-RemitMD-Voucher": json.dumps(voucher)},
            )

            if llm_resp.status_code == 200:
                successful_calls += 1
                data = llm_resp.json()
                print(f"  Call {i + 1}/{CALLS_TO_MAKE}: ✓ ({data['usage']['total_tokens']} tokens)")
            else:
                print(f"  Call {i + 1}/{CALLS_TO_MAKE}: ✗ HTTP {llm_resp.status_code}")

        assert successful_calls == CALLS_TO_MAKE, (
            f"Expected {CALLS_TO_MAKE} successful calls, got {successful_calls}"
        )

        # -- Step 4: Verify charges --------------------------------------------
        print("→ Verifying charges...")
        tab_status_resp = await client.get(
            f"{REMITMD_API_URL}/api/v0/tabs/{tab_id}",
            headers={"X-RemitMD-Key": AGENT_KEY},
        )
        tab_status_resp.raise_for_status()
        tab_status: dict[str, Any] = tab_status_resp.json()

        charged_usd = float(tab_status.get("charged_usd", 0))
        tolerance = 0.001
        assert abs(charged_usd - EXPECTED_TOTAL_USD) < tolerance, (
            f"Expected ${EXPECTED_TOTAL_USD:.3f} charged, got ${charged_usd:.3f}"
        )
        print(f"  Charged: ${charged_usd:.3f} (expected ${EXPECTED_TOTAL_USD:.3f}) ✓")

        # -- Step 5: Close tab -------------------------------------------------
        print("→ Closing tab...")
        close_resp = await client.post(
            f"{REMITMD_API_URL}/api/v0/tabs/{tab_id}/close",
            headers={"X-RemitMD-Key": AGENT_KEY},
        )
        close_resp.raise_for_status()
        close_data: dict[str, Any] = close_resp.json()

        # -- Step 6: Verify refund ---------------------------------------------
        refund_usd = float(close_data.get("refund_usd", 0))
        expected_refund = TAB_LIMIT_USD - EXPECTED_TOTAL_USD
        assert abs(refund_usd - expected_refund) < tolerance, (
            f"Expected ${expected_refund:.2f} refund, got ${refund_usd:.2f}"
        )
        print(f"  Tab closed. Refund: ${refund_usd:.2f} (expected ${expected_refund:.2f}) ✓")
        print(f"  Final: {CALLS_TO_MAKE} calls made, ${charged_usd:.3f} charged, ${refund_usd:.2f} refunded")
