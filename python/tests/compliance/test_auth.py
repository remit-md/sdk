"""Compliance: EIP-712 authentication against a real server.

Proves that the Python SDK can authenticate - 200 responses, not 401s.
"""

from __future__ import annotations

import pytest

from .conftest import server_available


@pytest.mark.asyncio
@server_available
async def test_authenticated_request_returns_200_not_401(wallet):
    """GET /api/v1/status/{address} with valid EIP-712 auth must return 200."""
    import httpx

    from .conftest import SERVER_URL

    print(f"[COMPLIANCE] auth test: building EIP-712 headers for {wallet.address}")
    headers = await wallet._http._build_auth_headers("GET", f"/api/v1/status/{wallet.address}")
    async with httpx.AsyncClient(base_url=SERVER_URL, timeout=10.0) as client:
        resp = await client.get(
            f"/api/v1/status/{wallet.address}",
            headers=headers,
        )
    print(f"[COMPLIANCE] auth: GET /api/v1/status/{wallet.address} -> {resp.status_code}")
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"


@pytest.mark.asyncio
@server_available
async def test_unauthenticated_request_returns_401(http):
    """POST /api/v1/payments/direct without auth headers must return 401."""
    import httpx

    from .conftest import SERVER_URL

    print("[COMPLIANCE] auth test: sending unauthenticated POST /api/v1/payments/direct")
    async with httpx.AsyncClient(base_url=SERVER_URL, timeout=10.0) as client:
        resp = await client.post(
            "/api/v1/payments/direct",
            json={
                "to": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
                "amount": 1.0,
            },
        )
    print(f"[COMPLIANCE] auth: unauthenticated POST -> {resp.status_code}")
    assert resp.status_code == 401, f"Expected 401, got {resp.status_code}: {resp.text}"


@pytest.mark.asyncio
@server_available
async def test_mint_credits_testnet_funds(wallet):
    """POST /api/v1/mint must return a tx_hash."""
    print(f"[COMPLIANCE] mint test: minting 100 USDC for {wallet.address}")
    result = await wallet.mint(100)
    print(f"[COMPLIANCE] mint: 100 USDC -> {wallet.address} tx={result['tx_hash']}")
    assert result["tx_hash"] is not None
