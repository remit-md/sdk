"""Tests for X402Client middleware."""

from __future__ import annotations

import base64
import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from remitmd.wallet import Wallet
from remitmd.x402 import AllowanceExceededError, X402Client

# Anvil account #0 — well-known test key.
_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
_ADDR = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# A dummy provider address for PAYMENT-REQUIRED headers.
_PROVIDER = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
_USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"


def _make_wallet() -> Wallet:
    return Wallet(private_key=_KEY, chain="localhost", testnet=True)


def _make_payment_required(
    amount: str = "100000",  # 0.10 USDC
    scheme: str = "exact",
    network: str = "eip155:31337",
    pay_to: str = _PROVIDER,
    max_timeout: int = 30,
    resource: str | None = None,
    description: str | None = None,
    mime_type: str | None = None,
) -> str:
    """Return a base64-encoded PAYMENT-REQUIRED header value."""
    payload: dict[str, object] = {
        "scheme": scheme,
        "network": network,
        "amount": amount,
        "asset": _USDC,
        "payTo": pay_to,
        "maxTimeoutSeconds": max_timeout,
    }
    if resource is not None:
        payload["resource"] = resource
    if description is not None:
        payload["description"] = description
    if mime_type is not None:
        payload["mimeType"] = mime_type
    return base64.b64encode(json.dumps(payload).encode()).decode()


def _mock_response(status: int, headers: dict[str, str] | None = None) -> MagicMock:
    """Return a mock httpx.Response."""
    r = MagicMock()
    r.status_code = status
    r.headers = headers or {}
    return r


# ─── Construction ─────────────────────────────────────────────────────────────


def test_x402client_repr() -> None:
    wallet = _make_wallet()
    client = X402Client(wallet=wallet, max_auto_pay_usdc=0.50)
    assert _ADDR in repr(client)
    assert "0.5" in repr(client)


def test_x402client_default_limit() -> None:
    wallet = _make_wallet()
    client = X402Client(wallet=wallet)
    assert client._max_auto_pay_usdc == 0.10


# ─── AllowanceExceededError ────────────────────────────────────────────────────


def test_allowance_exceeded_error_message() -> None:
    err = AllowanceExceededError(0.5, 0.1)
    assert "0.500000" in str(err)
    assert "0.100000" in str(err)
    assert err.amount_usdc == 0.5
    assert err.limit_usdc == 0.1


# ─── 402 handling ─────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_passes_through_200() -> None:
    """Non-402 responses are returned unchanged."""
    wallet = _make_wallet()
    client = X402Client(wallet=wallet, max_auto_pay_usdc=1.0)
    ok_response = _mock_response(200)

    with patch.object(client._http, "request", new=AsyncMock(return_value=ok_response)):
        result = await client.get("http://example.com/data")

    assert result.status_code == 200


@pytest.mark.asyncio
async def test_raises_when_payment_required_missing() -> None:
    """402 without PAYMENT-REQUIRED header raises ValueError."""
    wallet = _make_wallet()
    client = X402Client(wallet=wallet, max_auto_pay_usdc=1.0)
    r402 = _mock_response(402, headers={})

    with patch.object(client._http, "request", new=AsyncMock(return_value=r402)):
        with pytest.raises(ValueError, match="PAYMENT-REQUIRED"):
            await client.get("http://example.com/data")


@pytest.mark.asyncio
async def test_raises_on_unsupported_scheme() -> None:
    """402 with scheme != "exact" raises ValueError."""
    wallet = _make_wallet()
    client = X402Client(wallet=wallet, max_auto_pay_usdc=1.0)
    header = _make_payment_required(scheme="upto")
    r402 = _mock_response(402, headers={"payment-required": header})

    with patch.object(client._http, "request", new=AsyncMock(return_value=r402)):
        with pytest.raises(ValueError, match="scheme"):
            await client.get("http://example.com/data")


@pytest.mark.asyncio
async def test_raises_allowance_exceeded() -> None:
    """402 where amount > limit raises AllowanceExceededError."""
    wallet = _make_wallet()
    client = X402Client(wallet=wallet, max_auto_pay_usdc=0.05)
    # 100000 base units = 0.10 USDC > 0.05 limit
    header = _make_payment_required(amount="100000")
    r402 = _mock_response(402, headers={"payment-required": header})

    with patch.object(client._http, "request", new=AsyncMock(return_value=r402)):
        with pytest.raises(AllowanceExceededError) as exc_info:
            await client.get("http://example.com/data")

    err = exc_info.value
    assert pytest.approx(err.amount_usdc, abs=1e-9) == 0.10
    assert pytest.approx(err.limit_usdc, abs=1e-9) == 0.05


@pytest.mark.asyncio
async def test_successful_payment_retry() -> None:
    """402 within limit: retries with PAYMENT-SIGNATURE header and returns 200."""
    wallet = _make_wallet()
    client = X402Client(wallet=wallet, max_auto_pay_usdc=1.0)

    header_402 = _make_payment_required(amount="100000")  # 0.10 USDC
    r402 = _mock_response(402, headers={"payment-required": header_402})
    r200 = _mock_response(200)

    call_count = 0
    captured_headers: dict[str, str] = {}

    async def mock_request(method: str, url: str, **kwargs: object) -> MagicMock:
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            return r402
        captured_headers.update(kwargs.get("headers", {}))  # type: ignore[arg-type]
        return r200

    with patch.object(client._http, "request", new=mock_request):
        result = await client.get("http://example.com/data")

    assert result.status_code == 200
    assert call_count == 2
    # PAYMENT-SIGNATURE must be present in the retry.
    assert "PAYMENT-SIGNATURE" in captured_headers

    # Decode and verify payload structure.
    raw = captured_headers["PAYMENT-SIGNATURE"]
    payload = json.loads(base64.b64decode(raw))
    assert payload["scheme"] == "exact"
    assert payload["network"] == "eip155:31337"
    assert payload["x402Version"] == 1
    auth = payload["payload"]["authorization"]
    assert auth["from"].lower() == _ADDR.lower()
    assert auth["to"].lower() == _PROVIDER.lower()
    assert auth["value"] == "100000"
    assert auth["validAfter"] == "0"
    assert auth["nonce"].startswith("0x")
    assert len(auth["nonce"]) == 66  # 0x + 64 hex chars = 32 bytes
    # Signature must be a non-empty hex string (65 bytes = 130 hex chars, may lack 0x prefix).
    sig = payload["payload"]["signature"]
    assert isinstance(sig, str) and len(sig) >= 130


@pytest.mark.asyncio
async def test_payment_chainid_parsed_from_network() -> None:
    """chainId is parsed from the CAIP-2 network string."""
    wallet = _make_wallet()
    client = X402Client(wallet=wallet, max_auto_pay_usdc=1.0)

    # Use Base Sepolia network (84532).
    header_402 = _make_payment_required(amount="1000", network="eip155:84532")
    r402 = _mock_response(402, headers={"payment-required": header_402})
    r200 = _mock_response(200)

    call_count = 0
    captured_headers: dict[str, str] = {}

    async def mock_request(method: str, url: str, **kwargs: object) -> MagicMock:
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            return r402
        captured_headers.update(kwargs.get("headers", {}))  # type: ignore[arg-type]
        return r200

    with patch.object(client._http, "request", new=mock_request):
        await client.get("http://example.com/resource")

    payload = json.loads(base64.b64decode(captured_headers["PAYMENT-SIGNATURE"]))
    assert payload["network"] == "eip155:84532"


@pytest.mark.asyncio
async def test_v2_fields_available_via_last_payment() -> None:
    """V2 optional fields (resource, description, mimeType) are exposed via last_payment."""
    wallet = _make_wallet()
    client = X402Client(wallet=wallet, max_auto_pay_usdc=1.0)
    header_402 = _make_payment_required(
        amount="1000",
        resource="/api/v0/premium",
        description="Access to premium data",
        mime_type="application/json",
    )
    r402 = _mock_response(402, headers={"payment-required": header_402})
    r200 = _mock_response(200)

    call_count = 0

    async def mock_request(method: str, url: str, **kwargs: object) -> MagicMock:
        nonlocal call_count
        call_count += 1
        return r402 if call_count == 1 else r200

    with patch.object(client._http, "request", new=mock_request):
        await client.get("http://example.com/api/v0/premium")

    assert client.last_payment is not None
    assert client.last_payment["resource"] == "/api/v0/premium"
    assert client.last_payment["description"] == "Access to premium data"
    assert client.last_payment["mimeType"] == "application/json"
