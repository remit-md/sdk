"""x402 service provider middleware for gating HTTP endpoints behind payments.

Providers use this module to:
- Return HTTP 402 responses with properly formatted ``PAYMENT-REQUIRED`` headers
- Verify incoming ``PAYMENT-SIGNATURE`` headers against the remit.md facilitator

Usage (FastAPI)::

    from remitmd.provider import X402Paywall

    paywall = X402Paywall(
        wallet_address="0xYourProviderWallet",
        amount_usdc=0.001,
        network="eip155:84532",
        asset="0x2d846325766921935f37d5b4478196d3ef93707c",
        facilitator_token="your-bearer-jwt",
        resource="/v1/data",
        description="Realtime market data feed",
        mime_type="application/json",
    )

    @app.get("/v1/data")
    async def get_data(payment=Depends(paywall.fastapi_dependency)):
        return {"data": "..."}

Usage (Flask)::

    @app.route("/v1/data")
    @paywall.flask_route()
    def get_data():
        return jsonify({"data": "..."})

Usage (raw ASGI / standalone)::

    payment_sig = request.headers.get("payment-signature")
    is_valid, reason = await paywall.check(payment_sig)
    if not is_valid:
        return build_402_response(paywall.payment_required_header())
"""

from __future__ import annotations

import base64
import json
from typing import Any

import httpx


class X402Paywall:
    """
    x402 paywall for service providers.

    Generates ``PAYMENT-REQUIRED`` headers for 402 responses and verifies
    ``PAYMENT-SIGNATURE`` headers by calling the remit.md facilitator.

    Args:
        wallet_address: Provider's checksummed Ethereum address (``payTo``).
        amount_usdc: Price per request in USDC (e.g. ``0.001``).
        network: CAIP-2 network string (e.g. ``"eip155:84532"`` for Base Sepolia).
        asset: USDC contract address on the target network.
        facilitator_url: Base URL of the remit.md facilitator.
        facilitator_token: Bearer JWT for calling ``/api/v1/x402/verify``.
        max_timeout_seconds: How long the payment authorization is valid.
        resource: V2 — URL or path of the resource being protected (e.g. ``"/v1/data"``).
        description: V2 — Human-readable description of what the payment is for.
        mime_type: V2 — MIME type of the resource (e.g. ``"application/json"``).
    """

    def __init__(
        self,
        wallet_address: str,
        amount_usdc: float,
        network: str,
        asset: str,
        facilitator_url: str = "https://remit.md",
        facilitator_token: str = "",
        max_timeout_seconds: int = 60,
        resource: str | None = None,
        description: str | None = None,
        mime_type: str | None = None,
    ) -> None:
        self._wallet_address = wallet_address
        self._amount_base_units = str(int(amount_usdc * 1_000_000))
        self._network = network
        self._asset = asset
        self._facilitator_url = facilitator_url.rstrip("/")
        self._facilitator_token = facilitator_token
        self._max_timeout_seconds = max_timeout_seconds
        self._resource = resource
        self._description = description
        self._mime_type = mime_type

    def payment_required_header(self) -> str:
        """Return the base64-encoded JSON ``PAYMENT-REQUIRED`` header value."""
        payload: dict[str, Any] = {
            "scheme": "exact",
            "network": self._network,
            "amount": self._amount_base_units,
            "asset": self._asset,
            "payTo": self._wallet_address,
            "maxTimeoutSeconds": self._max_timeout_seconds,
        }
        if self._resource is not None:
            payload["resource"] = self._resource
        if self._description is not None:
            payload["description"] = self._description
        if self._mime_type is not None:
            payload["mimeType"] = self._mime_type
        return base64.b64encode(json.dumps(payload).encode()).decode()

    def _payment_required_object(self) -> dict[str, Any]:
        """Return the PaymentRequired dict for the facilitator verify call."""
        return {
            "scheme": "exact",
            "network": self._network,
            "amount": self._amount_base_units,
            "asset": self._asset,
            "payTo": self._wallet_address,
            "maxTimeoutSeconds": self._max_timeout_seconds,
        }

    async def check(self, payment_sig: str | None) -> tuple[bool, str | None]:
        """
        Check whether a ``PAYMENT-SIGNATURE`` header represents a valid payment.

        Args:
            payment_sig: The raw header value (base64 JSON), or ``None`` if absent.

        Returns:
            ``(True, None)`` if payment is valid.
            ``(False, reason)`` if invalid, where ``reason`` is a string like
            ``"SIGNATURE_INVALID"`` or ``None`` if the header was simply absent.
        """
        if not payment_sig:
            return False, None

        try:
            payment_payload = json.loads(base64.b64decode(payment_sig))
        except Exception:
            return False, "INVALID_PAYLOAD"

        body = {
            "paymentPayload": payment_payload,
            "paymentRequired": self._payment_required_object(),
        }
        headers: dict[str, str] = {"Content-Type": "application/json"}
        if self._facilitator_token:
            headers["Authorization"] = f"Bearer {self._facilitator_token}"

        async with httpx.AsyncClient() as client:
            try:
                resp = await client.post(
                    f"{self._facilitator_url}/api/v1/x402/verify",
                    json=body,
                    headers=headers,
                    timeout=10.0,
                )
                resp.raise_for_status()
                data = resp.json()
            except Exception:
                return False, "FACILITATOR_ERROR"

        is_valid: bool = bool(data.get("isValid", False))
        invalid_reason: str | None = data.get("invalidReason")
        return is_valid, invalid_reason

    async def fastapi_dependency(self, request: Any) -> None:
        """
        FastAPI ``Depends()`` dependency.

        Raises ``HTTPException(402)`` with ``PAYMENT-REQUIRED`` header if
        payment is absent or invalid.

        Example::

            @app.get("/v1/data")
            async def get_data(payment=Depends(paywall.fastapi_dependency)):
                return {"data": "..."}
        """
        try:
            from fastapi import HTTPException
            from starlette.requests import Request as StarletteRequest  # type: ignore[import]
        except ImportError as exc:
            raise ImportError(
                "fastapi_dependency() requires FastAPI to be installed. Run: pip install fastapi"
            ) from exc

        if not isinstance(request, StarletteRequest):
            raise TypeError(
                "fastapi_dependency() must be used as a FastAPI Depends() dependency"
                " that injects the Request object."
            )

        payment_sig = request.headers.get("payment-signature")
        is_valid, reason = await self.check(payment_sig)
        if not is_valid:
            raise HTTPException(
                status_code=402,
                detail={"error": "Payment required", "invalidReason": reason},
                headers={"PAYMENT-REQUIRED": self.payment_required_header()},
            )

    def flask_route(self) -> Any:
        """
        Flask route decorator that enforces x402 payment before the view runs.

        Requires Flask to be installed (``pip install flask``).
        Works with both sync and async Flask view functions.

        Example::

            @app.route("/v1/data")
            @paywall.flask_route()
            def get_data():
                return jsonify({"data": "..."})
        """
        import asyncio
        import functools

        def decorator(f: Any) -> Any:
            @functools.wraps(f)
            def wrapper(*args: Any, **kwargs: Any) -> Any:
                try:
                    from flask import Response as FlaskResponse
                    from flask import request as flask_request
                except ImportError as exc:
                    raise ImportError(
                        "flask_route() requires Flask to be installed. Run: pip install flask"
                    ) from exc

                payment_sig = flask_request.headers.get("payment-signature")
                ok, _reason = asyncio.run(self.check(payment_sig))
                if not ok:
                    return FlaskResponse(
                        response='{"error":"Payment required"}',
                        status=402,
                        mimetype="application/json",
                        headers={"PAYMENT-REQUIRED": self.payment_required_header()},
                    )
                return f(*args, **kwargs)

            return wrapper

        return decorator

    def __repr__(self) -> str:
        return (
            f"X402Paywall(wallet={self._wallet_address!r},"
            f" amount_base_units={self._amount_base_units!r},"
            f" network={self._network!r})"
        )
