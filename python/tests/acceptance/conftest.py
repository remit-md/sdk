"""
Python SDK acceptance test fixtures.

Creates wallets against the live Base Sepolia API, mints testnet USDC,
and provides RPC-based balance checking.
"""

import asyncio
import os
import secrets
import time

import httpx

from remitmd.wallet import Wallet

API_URL = os.environ.get("ACCEPTANCE_API_URL", "https://remit.md")
RPC_URL = os.environ.get("ACCEPTANCE_RPC_URL", "https://sepolia.base.org")
USDC_ADDRESS = "0x142aD61B8d2edD6b3807D9266866D97C35Ee0317"
FEE_WALLET = "0xd3f721BDF92a2bB5Dd8d2FE2AFC03aFE5629B420"


async def _get_router_address() -> str:
    """Fetch router address from /contracts."""
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"{API_URL}/api/v0/contracts")
        resp.raise_for_status()
        return resp.json()["router"]


_router: str | None = None


async def get_router() -> str:
    global _router  # noqa: PLW0603
    if _router is None:
        _router = await _get_router_address()
    return _router


async def create_wallet() -> Wallet:
    """Create a fresh wallet pointing at the live API."""
    key = "0x" + secrets.token_hex(32)
    router = await get_router()
    return Wallet(
        private_key=key,
        chain="base-sepolia",
        api_url=API_URL,
        router_address=router,
    )


async def get_usdc_balance(address: str) -> float:
    """Read USDC balance via RPC eth_call to balanceOf(address)."""
    padded = address.lower().replace("0x", "").zfill(64)
    data = f"0x70a08231{padded}"

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            RPC_URL,
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "eth_call",
                "params": [{"to": USDC_ADDRESS, "data": data}, "latest"],
            },
        )
        result = resp.json()
        if "error" in result:
            raise RuntimeError(f"RPC error: {result['error']}")
        return int(result["result"], 16) / 1e6


async def get_fee_wallet_balance() -> float:
    return await get_usdc_balance(FEE_WALLET)


async def wait_for_balance_change(
    address: str,
    before: float,
    max_wait: float = 30.0,
) -> float:
    """Poll until balance differs from `before`."""
    start = time.monotonic()
    while time.monotonic() - start < max_wait:
        current = await get_usdc_balance(address)
        if abs(current - before) > 0.0001:
            return current
        await asyncio.sleep(2.0)
    return await get_usdc_balance(address)


def assert_balance_change(
    label: str,
    before: float,
    after: float,
    expected_delta: float,
    tolerance_bps: int = 10,
) -> None:
    """Assert a balance changed by the expected delta within tolerance."""
    actual = after - before
    tolerance = abs(expected_delta) * (tolerance_bps / 10000)
    diff = abs(actual - expected_delta)
    assert diff <= tolerance, (
        f"{label}: expected delta {expected_delta}, got {actual} "
        f"(before={before}, after={after}, tolerance={tolerance})"
    )


async def fund_wallet(wallet: Wallet, amount: float = 100) -> None:
    """Mint testnet USDC and wait for on-chain confirmation."""
    await wallet.mint(amount)
    await wait_for_balance_change(wallet.address, 0)
