"""Tests for X402Paywall service provider middleware."""

from __future__ import annotations

import base64
import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from remitmd.provider import X402Paywall

_WALLET = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
_USDC = "0x142aD61B8d2edD6b3807D9266866D97C35Ee0317"
_NETWORK = "eip155:31337"


def _make_paywall(**kwargs: object) -> X402Paywall:
    return X402Paywall(
        wallet_address=_WALLET,
        amount_usdc=kwargs.pop("amount_usdc", 0.001),  # type: ignore[arg-type]
        network=kwargs.pop("network", _NETWORK),  # type: ignore[arg-type]
        asset=kwargs.pop("asset", _USDC),  # type: ignore[arg-type]
        facilitator_url=kwargs.pop("facilitator_url", "http://localhost:3000"),  # type: ignore[arg-type]
        facilitator_token=kwargs.pop("facilitator_token", "test-token"),  # type: ignore[arg-type]
        **kwargs,
    )


def _encode_payload(payload: dict[str, object]) -> str:
    return base64.b64encode(json.dumps(payload).encode()).decode()


# ─── Construction ─────────────────────────────────────────────────────────────


def test_paywall_repr() -> None:
    pw = _make_paywall()
    assert _WALLET in repr(pw)
    assert _NETWORK in repr(pw)


def test_amount_converted_to_base_units() -> None:
    pw = X402Paywall(
        wallet_address=_WALLET,
        amount_usdc=0.001,
        network=_NETWORK,
        asset=_USDC,
    )
    header = json.loads(base64.b64decode(pw.payment_required_header()))
    assert header["amount"] == "1000"  # 0.001 USDC * 1_000_000


# ─── payment_required_header ──────────────────────────────────────────────────


def test_payment_required_header_structure() -> None:
    pw = _make_paywall(amount_usdc=0.005)
    raw = pw.payment_required_header()
    payload = json.loads(base64.b64decode(raw))

    assert payload["scheme"] == "exact"
    assert payload["network"] == _NETWORK
    assert payload["amount"] == "5000"  # 0.005 USDC
    assert payload["asset"] == _USDC
    assert payload["payTo"] == _WALLET
    assert isinstance(payload["maxTimeoutSeconds"], int)


def test_payment_required_header_v2_fields() -> None:
    from remitmd.provider import X402Paywall

    pw = X402Paywall(
        wallet_address=_WALLET,
        amount_usdc=0.001,
        network=_NETWORK,
        asset=_USDC,
        resource="/v1/data",
        description="Market data feed",
        mime_type="application/json",
    )
    payload = json.loads(base64.b64decode(pw.payment_required_header()))
    assert payload["resource"] == "/v1/data"
    assert payload["description"] == "Market data feed"
    assert payload["mimeType"] == "application/json"


def test_payment_required_header_v2_fields_absent_by_default() -> None:
    pw = _make_paywall()
    payload = json.loads(base64.b64decode(pw.payment_required_header()))
    assert "resource" not in payload
    assert "description" not in payload
    assert "mimeType" not in payload


# ─── check — no signature ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_check_returns_false_when_no_signature() -> None:
    pw = _make_paywall()
    is_valid, reason = await pw.check(None)
    assert is_valid is False
    assert reason is None  # absent header, not an error


@pytest.mark.asyncio
async def test_check_returns_false_for_empty_string() -> None:
    pw = _make_paywall()
    is_valid, reason = await pw.check("")
    assert is_valid is False
    assert reason is None


# ─── check — malformed payload ────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_check_returns_false_for_non_base64() -> None:
    pw = _make_paywall()
    is_valid, reason = await pw.check("not-valid-base64!!!")
    assert is_valid is False
    assert reason == "INVALID_PAYLOAD"


# ─── check — facilitator call ─────────────────────────────────────────────────


def _make_dummy_payment_sig() -> str:
    """Build a syntactically valid (but not cryptographically verified) PAYMENT-SIGNATURE."""
    payload = {
        "scheme": "exact",
        "network": _NETWORK,
        "x402Version": 1,
        "payload": {
            "signature": "0xdeadbeef",
            "authorization": {
                "from": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
                "to": _WALLET,
                "value": "1000",
                "validAfter": "0",
                "validBefore": "9999999999",
                "nonce": "0xabcd1234",
            },
        },
    }
    return base64.b64encode(json.dumps(payload).encode()).decode()


@pytest.mark.asyncio
async def test_check_calls_facilitator_and_returns_valid() -> None:
    pw = _make_paywall()
    payment_sig = _make_dummy_payment_sig()

    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_response.json = MagicMock(return_value={"isValid": True})

    with patch("httpx.AsyncClient") as mock_client_class:
        mock_client = AsyncMock()
        mock_client_class.return_value.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client_class.return_value.__aexit__ = AsyncMock(return_value=None)
        mock_client.post = AsyncMock(return_value=mock_response)

        is_valid, reason = await pw.check(payment_sig)

    assert is_valid is True
    assert reason is None

    # Verify the facilitator was called with correct body.
    call_kwargs = mock_client.post.call_args
    assert "/api/v0/x402/verify" in call_kwargs.args[0]
    body = call_kwargs.kwargs["json"]
    assert body["paymentRequired"]["payTo"] == _WALLET
    assert body["paymentRequired"]["amount"] == "1000"
    assert body["paymentRequired"]["network"] == _NETWORK
    assert call_kwargs.kwargs["headers"].get("Authorization") == "Bearer test-token"


@pytest.mark.asyncio
async def test_check_returns_false_when_facilitator_says_invalid() -> None:
    pw = _make_paywall()
    payment_sig = _make_dummy_payment_sig()

    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_response.json = MagicMock(
        return_value={"isValid": False, "invalidReason": "SIGNATURE_INVALID"}
    )

    with patch("httpx.AsyncClient") as mock_client_class:
        mock_client = AsyncMock()
        mock_client_class.return_value.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client_class.return_value.__aexit__ = AsyncMock(return_value=None)
        mock_client.post = AsyncMock(return_value=mock_response)

        is_valid, reason = await pw.check(payment_sig)

    assert is_valid is False
    assert reason == "SIGNATURE_INVALID"


@pytest.mark.asyncio
async def test_check_returns_facilitator_error_on_exception() -> None:
    pw = _make_paywall()
    payment_sig = _make_dummy_payment_sig()

    with patch("httpx.AsyncClient") as mock_client_class:
        mock_client = AsyncMock()
        mock_client_class.return_value.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client_class.return_value.__aexit__ = AsyncMock(return_value=None)
        mock_client.post = AsyncMock(side_effect=Exception("connection refused"))

        is_valid, reason = await pw.check(payment_sig)

    assert is_valid is False
    assert reason == "FACILITATOR_ERROR"


@pytest.mark.asyncio
async def test_check_omits_auth_header_when_no_token() -> None:
    pw = X402Paywall(
        wallet_address=_WALLET,
        amount_usdc=0.001,
        network=_NETWORK,
        asset=_USDC,
        facilitator_url="http://localhost:3000",
    )
    payment_sig = _make_dummy_payment_sig()

    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_response.json = MagicMock(return_value={"isValid": True})

    with patch("httpx.AsyncClient") as mock_client_class:
        mock_client = AsyncMock()
        mock_client_class.return_value.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client_class.return_value.__aexit__ = AsyncMock(return_value=None)
        mock_client.post = AsyncMock(return_value=mock_response)

        await pw.check(payment_sig)

    headers = mock_client.post.call_args.kwargs["headers"]
    assert "Authorization" not in headers
