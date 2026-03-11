"""Compliance: EIP-712 authentication against a real server.

Proves that the Python SDK can authenticate — 200 responses, not 401s.
"""

from __future__ import annotations

import pytest

from .conftest import server_available


@pytest.mark.asyncio
@server_available
async def test_authenticated_request_returns_200_not_401(wallet):
    """GET /api/v0/status/{address} with valid EIP-712 auth must return 200."""
    from remitmd.models.common import WalletStatus

    status = await wallet.status()
    assert isinstance(status, WalletStatus)
    assert status.address.lower() == wallet.address.lower()


@pytest.mark.asyncio
@server_available
async def test_unauthenticated_request_returns_401(http):
    """POST /api/v0/payments/direct without auth headers must return 401."""
    import httpx

    from .conftest import SERVER_URL

    async with httpx.AsyncClient(base_url=SERVER_URL, timeout=10.0) as client:
        resp = await client.post(
            "/api/v0/payments/direct",
            json={"to": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", "amount": 1.0},
        )
    assert resp.status_code == 401, f"Expected 401, got {resp.status_code}: {resp.text}"


@pytest.mark.asyncio
@server_available
async def test_faucet_credits_testnet_funds(wallet):
    """POST /api/v0/faucet must credit funds to the wallet address."""
    tx = await wallet.request_testnet_funds()
    assert tx.tx_hash is not None
    # Balance must be positive after faucet
    balance = await wallet.balance()
    assert balance > 0.0, f"Expected positive balance after faucet, got {balance}"


@pytest.mark.asyncio
@server_available
async def test_events_empty_for_new_wallet(wallet):
    """GET /api/v0/events returns empty list for a fresh wallet (before any activity)."""
    # wallet.get_events makes an authenticated EIP-712-signed GET request
    events = await wallet.get_events(wallet.address)
    assert isinstance(events, list)
    assert len(events) == 0, f"Expected empty events for new wallet, got {events}"
