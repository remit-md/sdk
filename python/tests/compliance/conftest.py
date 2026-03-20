"""Shared fixtures for compliance tests.

Compliance tests run against a real server started via docker-compose.compliance.yml.
They are skipped if the server is not reachable.

Environment variables:
  REMIT_TEST_SERVER_URL      Server base URL (default: http://localhost:3000)
  REMIT_ROUTER_ADDRESS       Router contract address for EIP-712 domain
                             (default: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8)
  REMIT_CHAIN_ID             Chain ID for EIP-712 domain (default: 84532)
"""

from __future__ import annotations

import os
import secrets

import httpx
import pytest
import pytest_asyncio

# ─── Config ───────────────────────────────────────────────────────────────────

SERVER_URL = os.environ.get("REMIT_TEST_SERVER_URL", "http://localhost:3000")
ROUTER_ADDRESS = os.environ.get(
    "REMIT_ROUTER_ADDRESS", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
)
CHAIN_ID = int(os.environ.get("REMIT_CHAIN_ID", "84532"))

# ─── Server availability check ────────────────────────────────────────────────


def _server_is_reachable() -> bool:
    """Return True if the compliance test server is up and healthy."""
    try:
        with httpx.Client(timeout=3.0) as client:
            resp = client.get(f"{SERVER_URL}/health")
            return resp.status_code == 200
    except Exception:
        return False


# Skip all tests in this package if the server is not available.
# This prevents CI failures when the compliance job is not run (e.g., draft PRs).
server_available = pytest.mark.skipif(
    not _server_is_reachable(),
    reason=f"Compliance server not reachable at {SERVER_URL}. "
    "Start it with: docker compose -f docker-compose.compliance.yml up -d",
)


# ─── Fixtures ─────────────────────────────────────────────────────────────────


@pytest_asyncio.fixture
async def http() -> httpx.AsyncClient:
    """Raw async HTTP client for setup calls (register, agent-key)."""
    async with httpx.AsyncClient(base_url=SERVER_URL, timeout=10.0) as client:
        yield client


def _generate_wallet() -> tuple[str, str]:
    """Generate a random private key and derive the wallet address.

    No server registration needed — the new auth model uses EIP-712 signatures.
    """
    from remitmd.wallet import Wallet

    private_key = "0x" + secrets.token_hex(32)
    wallet = Wallet(
        private_key=private_key,
        chain="base-sepolia",
        testnet=True,
        api_url=SERVER_URL,
        router_address=ROUTER_ADDRESS,
    )
    return private_key, wallet.address


@pytest_asyncio.fixture
async def wallet():
    """A fully initialised Wallet backed by a random keypair."""
    from remitmd.wallet import Wallet

    private_key, _ = _generate_wallet()
    w = Wallet(
        private_key=private_key,
        chain="base-sepolia",
        testnet=True,
        api_url=SERVER_URL,
        router_address=ROUTER_ADDRESS,
    )
    yield w
    await w.close()


@pytest_asyncio.fixture
async def funded_wallet(wallet):
    """A Wallet that has received testnet USDC via mint."""
    result = await wallet.mint(100)
    assert result["tx_hash"] is not None
    return wallet


@pytest_asyncio.fixture
async def wallet_pair():
    """Two separate wallets (payer and payee) for transfer tests."""
    from remitmd.wallet import Wallet

    pk_a, _ = _generate_wallet()
    pk_b, addr_b = _generate_wallet()

    payer = Wallet(
        private_key=pk_a,
        chain="base-sepolia",
        testnet=True,
        api_url=SERVER_URL,
        router_address=ROUTER_ADDRESS,
    )
    payee = Wallet(
        private_key=pk_b,
        chain="base-sepolia",
        testnet=True,
        api_url=SERVER_URL,
        router_address=ROUTER_ADDRESS,
    )
    # Fund payer via mint
    await payer.mint(100)

    yield payer, payee, addr_b

    await payer.close()
    await payee.close()
