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
    import httpx

    from .conftest import CHAIN_ID, ROUTER_ADDRESS, SERVER_URL

    # Debug 1: Verify golden vector locally to prove signing works in this env
    from eth_account import Account
    from eth_account.messages import encode_typed_data

    anvil_key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    anvil_account = Account.from_key(anvil_key)
    gv_domain = {
        "name": "remit.md",
        "version": "0.1",
        "chainId": 84532,
        "verifyingContract": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    }
    gv_types = {
        "APIRequest": [
            {"name": "method", "type": "string"},
            {"name": "path", "type": "string"},
            {"name": "timestamp", "type": "uint256"},
            {"name": "nonce", "type": "bytes32"},
        ]
    }
    gv_value = {
        "method": "POST",
        "path": "/api/v0/escrows",
        "timestamp": 1741400000,
        "nonce": "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    }
    gv_structured = encode_typed_data(domain_data=gv_domain, message_types=gv_types, message_data=gv_value)
    gv_signed = anvil_account.sign_message(gv_structured)
    gv_sig = "0x" + gv_signed.signature.hex()
    expected_sig = "0x212e1bd57500efed284d08bb7531ea752089f28aef4f8831d19814e6f03eabd354b038e4b679a59325ef4ef2d158b84f1197c699888d40508cdffad453998dbe1b"
    print(f"\n=== GV CHECK: sig match = {gv_sig == expected_sig}")
    if gv_sig != expected_sig:
        print(f"=== GV expected: {expected_sig}")
        print(f"=== GV got:      {gv_sig}")

    # Debug 2: Build headers and show full details
    headers = await wallet._http._build_auth_headers("GET", f"/api/v0/status/{wallet.address}")
    sig = headers["X-Remit-Signature"]
    print(f"=== SIG len={len(sig)} last4={sig[-4:]}")
    print(f"=== AGENT: {headers['X-Remit-Agent']}")
    print(f"=== TS: {headers['X-Remit-Timestamp']}")
    print(f"=== NONCE len={len(headers['X-Remit-Nonce'])}")
    print(f"=== chain_id={wallet._http._chain_id} contract={wallet._http._verifying_contract}")

    # Debug 3: Also try with Anvil #0 key against the server (fresh timestamp)
    from remitmd.signer import PrivateKeySigner
    from remitmd._http import AuthenticatedClient

    anvil_signer = PrivateKeySigner(anvil_key)
    anvil_http = AuthenticatedClient(
        SERVER_URL, signer=anvil_signer, chain_id=CHAIN_ID,
        verifying_contract=ROUTER_ADDRESS,
    )
    anvil_addr = anvil_signer.get_address()
    anvil_headers = await anvil_http._build_auth_headers("GET", f"/api/v0/status/{anvil_addr}")
    async with httpx.AsyncClient(base_url=SERVER_URL, timeout=10.0) as client:
        anvil_resp = await client.get(
            f"/api/v0/status/{anvil_addr}",
            headers=anvil_headers,
        )
    print(f"=== ANVIL status_code={anvil_resp.status_code} body={anvil_resp.text[:200]}")
    await anvil_http.close()

    # Debug 4: Now try with the actual wallet
    async with httpx.AsyncClient(base_url=SERVER_URL, timeout=10.0) as client:
        resp = await client.get(
            f"/api/v0/status/{wallet.address}",
            headers=headers,
        )
    print(f"=== WALLET status_code={resp.status_code} body={resp.text[:200]}")
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"


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
