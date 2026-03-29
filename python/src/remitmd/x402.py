"""x402 client middleware for auto-paying HTTP 402 Payment Required responses.

x402 is an open payment standard where resource servers return HTTP 402 with
a ``PAYMENT-REQUIRED`` header describing the cost. This module provides an
httpx wrapper that intercepts those responses, signs an EIP-3009 authorization
via the server's ``/x402/prepare`` endpoint, and retries the request with a
``PAYMENT-SIGNATURE`` header.

Usage::

    from remitmd import Wallet, PrivateKeySigner
    from remitmd.x402 import X402Client

    signer = PrivateKeySigner("0x...")
    wallet = Wallet(signer=signer, chain="base-sepolia", testnet=True)
    client = X402Client(wallet=wallet, max_auto_pay_usdc=0.10)

    async with client:
        response = await client.get("https://api.provider.com/v1/data")
"""

from __future__ import annotations

import base64
import json
from typing import Any

import httpx

from remitmd.signer import Signer


class AllowanceExceededError(Exception):
    """Raised when an x402 payment exceeds the configured auto-pay limit."""

    def __init__(self, amount_usdc: float, limit_usdc: float) -> None:
        super().__init__(
            f"x402 payment {amount_usdc:.6f} USDC exceeds auto-pay limit {limit_usdc:.6f} USDC"
        )
        self.amount_usdc = amount_usdc
        self.limit_usdc = limit_usdc


class X402Client:
    """
    httpx wrapper that auto-handles HTTP 402 Payment Required responses.

    On receiving a 402, the client:

    1. Decodes the ``PAYMENT-REQUIRED`` header (base64 JSON)
    2. Checks the amount is within ``max_auto_pay_usdc``
    3. Builds and signs an EIP-3009 ``transferWithAuthorization``
    4. Base64-encodes the ``PAYMENT-SIGNATURE`` header
    5. Retries the original request with payment attached

    V2 note: the decoded ``PAYMENT-REQUIRED`` header may include optional
    ``resource``, ``description``, and ``mimeType`` fields. After a payment
    is made, access them via ``client.last_payment["resource"]`` etc.

    Args:
        wallet: remit.md ``Wallet`` (provides address and signing capability).
        max_auto_pay_usdc: Maximum USDC amount to auto-pay per request.
        timeout: HTTP timeout in seconds.
    """

    def __init__(
        self,
        wallet: Any,  # remitmd.wallet.Wallet - avoid circular import
        max_auto_pay_usdc: float = 0.10,
        timeout: float = 30.0,
    ) -> None:
        self._signer: Signer = wallet._signer
        self._address: str = wallet.address
        self._max_auto_pay_usdc = max_auto_pay_usdc
        self._http = httpx.AsyncClient(timeout=timeout)
        self._api_http = wallet._http  # Authenticated Remit API client
        # Set after each payment; contains V2 fields (resource, description, mimeType) if provided.
        self.last_payment: dict[str, Any] | None = None

    # ─── Public request methods ────────────────────────────────────────────────

    async def get(self, url: str, **kwargs: Any) -> httpx.Response:
        """GET request with automatic x402 payment handling."""
        return await self.request("GET", url, **kwargs)

    async def post(self, url: str, **kwargs: Any) -> httpx.Response:
        """POST request with automatic x402 payment handling."""
        return await self.request("POST", url, **kwargs)

    async def request(self, method: str, url: str, **kwargs: Any) -> httpx.Response:
        """Generic request with automatic x402 payment handling."""
        response = await self._http.request(method, url, **kwargs)
        if response.status_code == 402:
            response = await self._handle_402(method, url, response, **kwargs)
        return response

    # ─── 402 handling ─────────────────────────────────────────────────────────

    async def _handle_402(
        self,
        method: str,
        url: str,
        response: httpx.Response,
        **kwargs: Any,
    ) -> httpx.Response:
        # 1. Decode PAYMENT-REQUIRED header (httpx normalises header names to lowercase).
        raw = response.headers.get("payment-required")
        if not raw:
            raise ValueError("402 response missing PAYMENT-REQUIRED header")

        required: dict[str, Any] = json.loads(base64.b64decode(raw))

        # 2. Only the "exact" scheme is supported.
        if required.get("scheme") != "exact":
            raise ValueError(f"Unsupported x402 scheme: {required.get('scheme')!r}")

        # Store for caller inspection (V2 fields: resource, description, mimeType).
        self.last_payment = required

        # 3. Check auto-pay limit.
        amount_base_units = int(required["amount"])
        amount_usdc = amount_base_units / 1_000_000
        if amount_usdc > self._max_auto_pay_usdc:
            raise AllowanceExceededError(amount_usdc, self._max_auto_pay_usdc)

        # 4. Call /x402/prepare to get the hash + authorization fields.
        prepare_data = await self._api_http.post(
            "/api/v1/x402/prepare",
            {"payment_required": raw, "payer": self._address},
        )

        # 5. Sign the hash.
        hash_bytes = bytes.fromhex(prepare_data["hash"][2:])
        signature = await self._signer.sign_hash(hash_bytes)

        # 6. Build PAYMENT-SIGNATURE JSON payload.
        network: str = required["network"]
        payment_payload = {
            "scheme": required["scheme"],
            "network": network,
            "x402Version": 1,
            "payload": {
                "signature": signature,
                "authorization": {
                    "from": prepare_data["from"],
                    "to": prepare_data["to"],
                    "value": prepare_data["value"],
                    "validAfter": prepare_data["valid_after"],
                    "validBefore": prepare_data["valid_before"],
                    "nonce": prepare_data["nonce"],
                },
            },
        }
        payment_header = base64.b64encode(json.dumps(payment_payload).encode()).decode()

        # 7. Retry with PAYMENT-SIGNATURE header.
        headers: dict[str, str] = dict(kwargs.pop("headers", {}))
        headers["PAYMENT-SIGNATURE"] = payment_header
        return await self._http.request(method, url, headers=headers, **kwargs)

    # ─── Context manager ───────────────────────────────────────────────────────

    async def close(self) -> None:
        await self._http.aclose()

    async def __aenter__(self) -> X402Client:
        return self

    async def __aexit__(self, *_: Any) -> None:
        await self.close()

    def __repr__(self) -> str:
        return (
            f"X402Client(address={self._address!r}, max_auto_pay_usdc={self._max_auto_pay_usdc!r})"
        )
