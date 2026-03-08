"""
Faucet scenario — request testnet USDC before running other scenarios.
"""

from __future__ import annotations

import os
from typing import Any

import httpx
from eth_account import Account  # type: ignore[import-untyped]

REMITMD_API_URL = os.environ.get("REMITMD_API_URL", "http://localhost:8080")
AGENT_KEY = os.environ.get(
    "REMITMD_KEY",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
)
CHAIN = os.environ.get("CHAIN_NAME", "base-sepolia")


def get_wallet_address(private_key: str) -> str:
    account = Account.from_key(private_key)
    return account.address


async def run() -> None:
    wallet = get_wallet_address(AGENT_KEY)
    async with httpx.AsyncClient(timeout=30) as client:
        print(f"→ Requesting testnet USDC for {wallet} on {CHAIN}...")
        resp = await client.post(
            f"{REMITMD_API_URL}/api/v0/faucet",
            json={"wallet": wallet, "chain": CHAIN},
        )
        if resp.status_code == 200:
            data: dict[str, Any] = resp.json()
            amount = data.get("amount_usd", "?")
            tx_hash = data.get("tx_hash", "N/A")
            print(f"  Received: ${amount} USDC testnet")
            print(f"  Tx: {tx_hash}")
        elif resp.status_code == 429:
            err: dict[str, Any] = resp.json()
            print(f"  Cooldown: {err.get('message', 'Already claimed recently')}")
            print("  Continuing with existing balance...")
        else:
            resp.raise_for_status()
