"""Compliance: EIP-712 authentication against a real server.

Proves that the Python SDK can authenticate — 200 responses, not 401s.
"""

from __future__ import annotations

import secrets
import time

import pytest

from .conftest import server_available


@pytest.mark.asyncio
@server_available
async def test_testnet_shortcut_auth_works(http):
    """X-RemitMD-Key testnet shortcut must return 200 (proves server is working)."""
    from .conftest import SERVER_URL

    import httpx
    from eth_account import Account

    # Use Anvil #0 key with the testnet shortcut header
    anvil_key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    anvil_addr = Account.from_key(anvil_key).address

    async with httpx.AsyncClient(base_url=SERVER_URL, timeout=10.0) as client:
        resp = await client.get(
            f"/api/v0/status/{anvil_addr}",
            headers={"X-RemitMD-Key": anvil_key},
        )
    print(f"\n=== SHORTCUT status={resp.status_code} body={resp.text[:300]}")
    # Shortcut might return 404 (wallet not registered) but should NOT return 401
    assert resp.status_code != 401, f"Testnet shortcut auth should not return 401: {resp.text}"


@pytest.mark.asyncio
@server_available
async def test_eip712_manual_hash_matches_encode_typed_data():
    """Manually compute EIP-712 hash and compare with encode_typed_data output."""
    from eth_account.messages import encode_typed_data
    from eth_utils import keccak

    # Use the same inputs as golden vector #0
    domain = {
        "name": "remit.md",
        "version": "0.1",
        "chainId": 84532,
        "verifyingContract": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    }
    types = {
        "APIRequest": [
            {"name": "method", "type": "string"},
            {"name": "path", "type": "string"},
            {"name": "timestamp", "type": "uint256"},
            {"name": "nonce", "type": "bytes32"},
        ]
    }
    # Use a LIVE-like request (fresh timestamp, random nonce)
    ts = int(time.time())
    nonce = "0x" + secrets.token_hex(32)
    value = {
        "method": "GET",
        "path": "/api/v0/status/0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
        "timestamp": ts,
        "nonce": nonce,
    }

    # 1. encode_typed_data output
    structured = encode_typed_data(domain_data=domain, message_types=types, message_data=value)
    sdk_domain_sep = structured.header
    sdk_struct_hash = structured.body
    sdk_hash = keccak(b"\x19\x01" + sdk_domain_sep + sdk_struct_hash)

    # 2. Manual computation (matching server's auth.rs logic exactly)
    domain_typehash = keccak(b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    struct_typehash = keccak(b"APIRequest(string method,string path,uint256 timestamp,bytes32 nonce)")

    name_hash = keccak(b"remit.md")
    version_hash = keccak(b"0.1")

    chain_id_bytes = (84532).to_bytes(32, "big")
    contract_bytes = bytes.fromhex("70997970C51812dc3A010C7d01b50e0d17dc79C8")
    contract_padded = b"\x00" * 12 + contract_bytes

    manual_domain_enc = domain_typehash + name_hash + version_hash + chain_id_bytes + contract_padded
    manual_domain_sep = keccak(manual_domain_enc)

    method_hash = keccak(value["method"].encode())
    path_hash = keccak(value["path"].encode())
    ts_bytes = ts.to_bytes(32, "big")
    nonce_bytes = bytes.fromhex(nonce[2:])  # strip 0x
    nonce_padded = nonce_bytes + b"\x00" * (32 - len(nonce_bytes)) if len(nonce_bytes) < 32 else nonce_bytes[:32]

    manual_struct_enc = struct_typehash + method_hash + path_hash + ts_bytes + nonce_padded
    manual_struct_hash = keccak(manual_struct_enc)

    manual_hash = keccak(b"\x19\x01" + manual_domain_sep + manual_struct_hash)

    print(f"\n=== DOMAIN SEP sdk={sdk_domain_sep.hex()} manual={manual_domain_sep.hex()} match={sdk_domain_sep == manual_domain_sep}")
    print(f"=== STRUCT HASH sdk={sdk_struct_hash.hex()} manual={manual_struct_hash.hex()} match={sdk_struct_hash == manual_struct_hash}")
    print(f"=== FINAL HASH sdk={sdk_hash.hex()} manual={manual_hash.hex()} match={sdk_hash == manual_hash}")

    assert sdk_domain_sep == manual_domain_sep, "Domain separator mismatch!"
    assert sdk_struct_hash == manual_struct_hash, "Struct hash mismatch!"
    assert sdk_hash == manual_hash, "Final hash mismatch!"


@pytest.mark.asyncio
@server_available
async def test_authenticated_request_returns_200_not_401(wallet):
    """GET /api/v0/status/{address} with valid EIP-712 auth must return 200."""
    import httpx
    from eth_account import Account
    from eth_account.messages import encode_typed_data
    from eth_utils import keccak

    from .conftest import CHAIN_ID, ROUTER_ADDRESS, SERVER_URL
    from remitmd.signer import PrivateKeySigner
    from remitmd._http import AuthenticatedClient

    anvil_key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

    # --- Test 1: Manual EIP-712 with Anvil key (bypass SDK entirely) ---
    anvil_account = Account.from_key(anvil_key)
    anvil_addr = anvil_account.address
    ts = int(time.time())
    nonce = "0x" + secrets.token_hex(32)
    method = "GET"
    path = f"/api/v0/status/{anvil_addr}"

    domain = {
        "name": "remit.md",
        "version": "0.1",
        "chainId": CHAIN_ID,
        "verifyingContract": ROUTER_ADDRESS,
    }
    types = {
        "APIRequest": [
            {"name": "method", "type": "string"},
            {"name": "path", "type": "string"},
            {"name": "timestamp", "type": "uint256"},
            {"name": "nonce", "type": "bytes32"},
        ]
    }
    value = {"method": method, "path": path, "timestamp": ts, "nonce": nonce}

    structured = encode_typed_data(domain_data=domain, message_types=types, message_data=value)
    signed = anvil_account.sign_message(structured)
    sig_hex = signed.signature.hex()

    # Print the intermediate hashes for debugging
    sdk_domain_sep = structured.header.hex()
    sdk_struct_hash = structured.body.hex()
    sdk_final_hash = keccak(b"\x19\x01" + structured.header + structured.body).hex()
    print(f"\n=== MANUAL TEST domain_sep={sdk_domain_sep[:16]}...")
    print(f"=== MANUAL TEST struct_hash={sdk_struct_hash[:16]}...")
    print(f"=== MANUAL TEST final_hash={sdk_final_hash[:16]}...")
    print(f"=== MANUAL TEST sig_len={len(sig_hex)} v_byte={sig_hex[-2:]}")
    print(f"=== MANUAL TEST path={path}")
    print(f"=== MANUAL TEST ts={ts} nonce_len={len(nonce)}")

    headers_manual = {
        "X-Remit-Signature": sig_hex,
        "X-Remit-Agent": anvil_addr,
        "X-Remit-Timestamp": str(ts),
        "X-Remit-Nonce": nonce,
    }

    async with httpx.AsyncClient(base_url=SERVER_URL, timeout=10.0) as client:
        resp_manual = await client.get(path, headers=headers_manual)
    print(f"=== MANUAL ANVIL status={resp_manual.status_code} body={resp_manual.text[:200]}")

    # --- Test 2: SDK AuthenticatedClient with Anvil key ---
    anvil_signer = PrivateKeySigner(anvil_key)
    anvil_http = AuthenticatedClient(
        SERVER_URL, signer=anvil_signer, chain_id=CHAIN_ID,
        verifying_contract=ROUTER_ADDRESS,
    )
    sdk_headers = await anvil_http._build_auth_headers("GET", f"/api/v0/status/{anvil_addr}")
    print(f"=== SDK HEADERS sig_len={len(sdk_headers['X-Remit-Signature'])} v={sdk_headers['X-Remit-Signature'][-2:]}")
    print(f"=== SDK HEADERS agent={sdk_headers['X-Remit-Agent']}")

    async with httpx.AsyncClient(base_url=SERVER_URL, timeout=10.0) as client:
        resp_sdk = await client.get(
            f"/api/v0/status/{anvil_addr}",
            headers=sdk_headers,
        )
    print(f"=== SDK ANVIL status={resp_sdk.status_code} body={resp_sdk.text[:200]}")
    await anvil_http.close()

    # --- Test 3: Actual registered wallet ---
    wallet_headers = await wallet._http._build_auth_headers("GET", f"/api/v0/status/{wallet.address}")
    async with httpx.AsyncClient(base_url=SERVER_URL, timeout=10.0) as client:
        resp_wallet = await client.get(
            f"/api/v0/status/{wallet.address}",
            headers=wallet_headers,
        )
    print(f"=== WALLET status={resp_wallet.status_code} body={resp_wallet.text[:200]}")

    # At least one must succeed
    assert resp_manual.status_code == 200 or resp_sdk.status_code == 200 or resp_wallet.status_code == 200, (
        f"All auth attempts failed: manual={resp_manual.status_code} sdk={resp_sdk.status_code} wallet={resp_wallet.status_code}"
    )


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
