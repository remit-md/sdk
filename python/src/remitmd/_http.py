"""Authenticated HTTP client with auto-retry, EIP-712 request signing, and error mapping.

Every outbound request is signed with EIP-712 so the API can verify the caller's
identity without a session cookie or bearer token.

Auth header format:
    X-Remit-Signature: <hex_sig>
    X-Remit-Agent: <checksummed_address>
    X-Remit-Timestamp: <unix_seconds>
    X-Remit-Nonce: <0x-prefixed 32-byte hex>

The signed payload is an EIP-712 typed struct:
    domain: {
        name: "remit.md",
        version: "0.1",
        chainId: <n>,
        verifyingContract: <router_address>,
    }
    type: APIRequest { method: string, path: string, timestamp: uint256, nonce: bytes32 }
"""

from __future__ import annotations

import os
import secrets
import time
from typing import Any

import httpx

from remitmd.errors import RateLimitExceeded, RemitError, from_error_code

# EIP-712 typed struct definition — must match server's auth.rs exactly.
_AUTH_TYPES = {
    "APIRequest": [
        {"name": "method", "type": "string"},
        {"name": "path", "type": "string"},
        {"name": "timestamp", "type": "uint256"},
        {"name": "nonce", "type": "bytes32"},
    ]
}

_MAX_RETRIES = 3
_RETRY_STATUSES = {429, 500, 502, 503, 504}


class AuthenticatedClient:
    """
    Thin httpx wrapper that:
    - Signs every request with EIP-712
    - Adds idempotency keys on POST/PUT
    - Retries on 429 / 5xx with exponential backoff
    - Maps API error responses to typed RemitError subclasses
    """

    def __init__(
        self,
        base_url: str,
        signer: Any | None,  # remitmd.signer.Signer | None
        chain_id: int,
        verifying_contract: str = "",
        timeout: float = 30.0,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._signer = signer
        self._chain_id = chain_id
        self._verifying_contract = verifying_contract
        self._client = httpx.AsyncClient(
            base_url=self._base_url,
            timeout=timeout,
            headers={"Content-Type": "application/json", "Accept": "application/json"},
        )

    async def get(self, path: str, **params: Any) -> Any:
        return await self._request("GET", path, params=params or None)

    async def post(self, path: str, body: dict[str, Any] | None = None) -> Any:
        return await self._request("POST", path, json=body)

    async def put(self, path: str, body: dict[str, Any] | None = None) -> Any:
        return await self._request("PUT", path, json=body)

    async def delete(self, path: str) -> Any:
        return await self._request("DELETE", path)

    async def _request(
        self,
        method: str,
        path: str,
        params: dict[str, Any] | None = None,
        json: dict[str, Any] | None = None,
    ) -> Any:
        # Idempotency key is fixed for all retries of the same logical operation.
        # Auth headers (including nonce) are regenerated on each attempt so that
        # a retry after a 5xx does not hit NONCE_REUSED on the server.
        idempotency_key = secrets.token_hex(16) if method in ("POST", "PUT") else None

        last_exc: Exception | None = None
        for attempt in range(_MAX_RETRIES + 1):
            if attempt > 0:
                # Exponential backoff: 1s, 2s, 4s
                wait = 2 ** (attempt - 1)
                await _async_sleep(wait)

            # Fresh nonce + timestamp on every attempt.
            headers = await self._build_auth_headers(method, path)
            if idempotency_key is not None:
                headers["X-Idempotency-Key"] = idempotency_key

            try:
                resp = await self._client.request(
                    method,
                    path,
                    headers=headers,
                    params=params,
                    json=json,
                )
            except httpx.RequestError as exc:
                last_exc = exc
                continue

            if resp.status_code == 429:
                last_exc = RateLimitExceeded("Rate limit exceeded", http_status=429)
                continue

            if resp.status_code >= 500 and attempt < _MAX_RETRIES:
                last_exc = Exception(f"Server error {resp.status_code}")
                continue

            return self._parse_response(resp)

        if last_exc is not None:
            raise last_exc
        raise Exception("Request failed after retries")  # pragma: no cover

    def _parse_response(self, resp: httpx.Response) -> Any:
        if resp.status_code == 204:
            return None

        try:
            data = resp.json()
        except ValueError as exc:
            if resp.is_success:
                raise RemitError(f"Non-JSON response body (status {resp.status_code})") from exc
            resp.raise_for_status()
            return None  # unreachable

        if not resp.is_success:
            code = data.get("code", "SERVER_ERROR") if isinstance(data, dict) else "SERVER_ERROR"
            message = data.get("message", resp.text) if isinstance(data, dict) else resp.text
            raise from_error_code(str(code), str(message), resp.status_code)

        return data

    async def _build_auth_headers(self, method: str, path: str) -> dict[str, str]:
        if self._signer is None:
            return {}

        timestamp = int(time.time())
        nonce = "0x" + secrets.token_hex(32)

        domain: dict[str, Any] = {
            "name": "remit.md",
            "version": "0.1",
            "chainId": self._chain_id,
            "verifyingContract": self._verifying_contract,
        }
        value = {
            "method": method.upper(),
            "path": path,
            "timestamp": timestamp,
            "nonce": nonce,
        }

        sig = await self._signer.sign_typed_data(domain, _AUTH_TYPES, value)
        address = self._signer.get_address()

        return {
            "X-Remit-Signature": sig,
            "X-Remit-Agent": address,
            "X-Remit-Timestamp": str(timestamp),
            "X-Remit-Nonce": nonce,
        }

    async def close(self) -> None:
        await self._client.aclose()

    async def __aenter__(self) -> AuthenticatedClient:
        return self

    async def __aexit__(self, *_: Any) -> None:
        await self.close()


async def _async_sleep(seconds: float) -> None:
    """Async sleep without importing asyncio at module level."""
    import asyncio  # noqa: PLC0415

    await asyncio.sleep(seconds)


# ─── Chain config ─────────────────────────────────────────────────────────────

_CHAIN_CONFIG: dict[str, dict[str, Any]] = {
    "base": {
        "chain_id": 8453,
        "api_url": os.environ.get("REMITMD_API_URL", "https://remit.md"),
    },
    "base-sepolia": {
        "chain_id": 84532,
        "api_url": os.environ.get("REMITMD_API_URL", "https://testnet.remit.md"),
    },
    "localhost": {
        "chain_id": 31337,
        "api_url": os.environ.get("REMITMD_API_URL", "http://localhost:3000"),
    },
}


def get_chain_config(chain: str, testnet: bool, api_url: str | None) -> tuple[int, str]:
    """Return (chain_id, api_url) for the given chain name."""
    # If testnet flag, force to sepolia variant
    key = chain
    if testnet and not chain.endswith("-sepolia") and chain != "localhost":
        key = f"{chain}-sepolia"

    cfg = _CHAIN_CONFIG.get(key)
    if cfg is None:
        raise ValueError(f"Unknown chain: {key!r}. Supported: {list(_CHAIN_CONFIG)}")

    url = api_url or cfg["api_url"]

    # Require HTTPS in production (not localhost / testnet)
    if not testnet and "localhost" not in url and not url.startswith("https://"):
        raise ValueError(f"API URL must use HTTPS in production: {url!r}")

    return int(cfg["chain_id"]), url
