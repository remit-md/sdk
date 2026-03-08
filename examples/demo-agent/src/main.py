"""
remit.md Demo Agent

Autonomous agent that demonstrates all 4 payment lifecycle scenarios:
  - tab_lifecycle:     Open tab → make calls → close → verify refund
  - escrow_lifecycle:  Create escrow → wait for work → verify + release
  - stream_lifecycle:  Open stream → wait → close → verify amounts
  - bounty_lifecycle:  Post bounty → submit solution → award
  - all:               Run all 4 scenarios in sequence
  - faucet:            Request testnet USDC (standalone)
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
from typing import Any

from dotenv import load_dotenv

load_dotenv(".env.testnet", override=False)
load_dotenv(".env", override=False)


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

REMITMD_API_URL = os.environ.get("REMITMD_API_URL", "http://localhost:8080")
LLM_API_URL = os.environ.get("LLM_API_URL", "http://localhost:3001")
DATA_API_URL = os.environ.get("DATA_API_URL", "http://localhost:3002")
CODE_REVIEW_URL = os.environ.get("CODE_REVIEW_URL", "http://localhost:3003")

AGENT_KEY = os.environ.get("REMITMD_KEY", "")
if not AGENT_KEY:
    # Development fallback — Anvil account #3
    AGENT_KEY = "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"

CHAIN_ID = int(os.environ.get("CHAIN_ID", "84532"))


# ---------------------------------------------------------------------------
# Minimal HTTP helpers (avoid extra dependencies)
# ---------------------------------------------------------------------------

async def api_get(path: str, params: dict[str, str] | None = None) -> dict[str, Any]:
    """GET the remit.md API."""
    import httpx
    async with httpx.AsyncClient(base_url=REMITMD_API_URL, timeout=30) as client:
        resp = await client.get(path, params=params)
        resp.raise_for_status()
        return resp.json()  # type: ignore[no-any-return]


async def api_post(path: str, body: dict[str, Any]) -> dict[str, Any]:
    """POST the remit.md API."""
    import httpx
    async with httpx.AsyncClient(base_url=REMITMD_API_URL, timeout=30) as client:
        resp = await client.post(path, json=body)
        resp.raise_for_status()
        return resp.json()  # type: ignore[no-any-return]


async def service_get(url: str, path: str, headers: dict[str, str] | None = None) -> dict[str, Any]:
    """GET a demo service."""
    import httpx
    async with httpx.AsyncClient(base_url=url, timeout=30) as client:
        resp = await client.get(path, headers=headers or {})
        resp.raise_for_status()
        return resp.json()  # type: ignore[no-any-return]


async def service_post(
    url: str,
    path: str,
    body: dict[str, Any],
    headers: dict[str, str] | None = None,
) -> dict[str, Any]:
    """POST a demo service."""
    import httpx
    async with httpx.AsyncClient(base_url=url, timeout=30) as client:
        resp = await client.post(path, json=body, headers=headers or {})
        resp.raise_for_status()
        return resp.json()  # type: ignore[no-any-return]


# ---------------------------------------------------------------------------
# Scenario runners — import lazily to keep startup fast
# ---------------------------------------------------------------------------

async def run_scenario(name: str) -> bool:
    """Run a named scenario. Returns True on success."""
    print(f"\n{'=' * 60}")
    print(f"  Scenario: {name}")
    print(f"{'=' * 60}")

    try:
        if name == "tab_lifecycle":
            from src.scenarios.tab_lifecycle import run
        elif name == "escrow_lifecycle":
            from src.scenarios.escrow_lifecycle import run
        elif name == "stream_lifecycle":
            from src.scenarios.stream_lifecycle import run
        elif name == "bounty_lifecycle":
            from src.scenarios.bounty_lifecycle import run
        elif name == "faucet":
            from src.scenarios.faucet import run  # type: ignore[no-redef]
        else:
            print(f"ERROR: Unknown scenario '{name}'")
            return False

        await run()
        print(f"\n✓ {name} PASSED")
        return True

    except Exception as exc:  # noqa: BLE001
        print(f"\n✗ {name} FAILED: {exc}")
        return False


async def run_all() -> bool:
    scenarios = ["tab_lifecycle", "escrow_lifecycle", "stream_lifecycle", "bounty_lifecycle"]
    results: dict[str, bool] = {}
    for scenario in scenarios:
        results[scenario] = await run_scenario(scenario)

    print(f"\n{'=' * 60}")
    print("  Summary")
    print(f"{'=' * 60}")
    for scenario, passed in results.items():
        status = "✓ PASS" if passed else "✗ FAIL"
        print(f"  {status}  {scenario}")

    return all(results.values())


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="remit.md demo agent — autonomous payment lifecycle demonstration"
    )
    parser.add_argument(
        "--scenario",
        choices=["tab_lifecycle", "escrow_lifecycle", "stream_lifecycle", "bounty_lifecycle", "faucet", "all"],
        default="all",
        help="Which scenario to run (default: all)",
    )
    parser.add_argument("--api-url", default=REMITMD_API_URL, help="remit.md API base URL")
    args = parser.parse_args()

    # Override globals if --api-url was supplied
    global REMITMD_API_URL  # noqa: PLW0603
    REMITMD_API_URL = args.api_url

    print(f"remit.md Demo Agent")
    print(f"  API:      {REMITMD_API_URL}")
    print(f"  Chain ID: {CHAIN_ID}")
    print(f"  Scenario: {args.scenario}")

    if args.scenario == "all":
        success = asyncio.run(run_all())
    else:
        success = asyncio.run(run_scenario(args.scenario))

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
