"""HTTP signer adapter for the remit local signer server.

Delegates EIP-712 signing to an HTTP server on localhost (typically
``http://127.0.0.1:7402``). The signer server holds the encrypted key;
this adapter only needs a bearer token and URL.

Usage::

    signer = await HttpSigner.create("http://127.0.0.1:7402", "rmit_sk_...")
    wallet = Wallet(signer=signer, chain="base")
"""

from __future__ import annotations

import httpx

from remitmd.signer import Signer


class HttpSigner(Signer):
    """Signer backed by a local HTTP signing server.

    - Bearer token is stored privately, never in repr/str.
    - Address is cached at construction time (GET /address).
    - sign_typed_data() POSTs structured EIP-712 data to /sign/typed-data.
    - All errors are explicit — no silent fallbacks.
    """

    def __init__(self, url: str, token: str) -> None:
        self._url = url.rstrip("/")
        self._token = token
        self._address: str | None = None

    @classmethod
    async def create(cls, url: str, token: str) -> HttpSigner:
        """Create an HttpSigner, fetching and caching the wallet address.

        Raises on network errors, auth failures, or missing address.
        """
        signer = cls(url, token)
        try:
            async with httpx.AsyncClient() as client:
                resp = await client.get(
                    f"{signer._url}/address",
                    headers={"Authorization": f"Bearer {token}"},
                    timeout=10.0,
                )
        except httpx.ConnectError as e:
            raise ConnectionError(f"HttpSigner: cannot reach signer server at {url}: {e}") from e

        if resp.status_code == 401:
            raise PermissionError("HttpSigner: unauthorized — check your REMIT_SIGNER_TOKEN")

        if not resp.is_success:
            raise RuntimeError(f"HttpSigner: GET /address failed ({resp.status_code}): {resp.text}")

        data = resp.json()
        if "address" not in data:
            raise RuntimeError("HttpSigner: GET /address returned no address")

        signer._address = data["address"]
        return signer

    def get_address(self) -> str:
        if not self._address:
            raise RuntimeError("HttpSigner not initialized. Use await HttpSigner.create()")
        return self._address

    async def sign_typed_data(
        self,
        domain: dict[str, object],
        types: dict[str, object],
        value: dict[str, object],
    ) -> str:
        try:
            async with httpx.AsyncClient() as client:
                resp = await client.post(
                    f"{self._url}/sign/typed-data",
                    headers={
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {self._token}",
                    },
                    json={"domain": domain, "types": types, "value": value},
                    timeout=10.0,
                )
        except httpx.ConnectError as e:
            raise ConnectionError(f"HttpSigner: cannot reach signer server: {e}") from e

        if resp.status_code == 401:
            raise PermissionError("HttpSigner: unauthorized — check your REMIT_SIGNER_TOKEN")

        if resp.status_code == 403:
            try:
                data = resp.json()
                reason = data.get("reason", "unknown")
            except Exception:
                reason = resp.text
            raise PermissionError(f"HttpSigner: policy denied — {reason}")

        if not resp.is_success:
            try:
                data = resp.json()
                detail = data.get("reason") or data.get("error") or resp.text
            except Exception:
                detail = resp.text
            raise RuntimeError(f"HttpSigner: sign failed ({resp.status_code}): {detail}")

        data = resp.json()
        sig = data.get("signature")
        if not sig:
            raise RuntimeError("HttpSigner: server returned no signature")
        return str(sig)

    # Never expose token in repr/str
    def __repr__(self) -> str:
        return f"HttpSigner(address={self._address!r})"

    def __str__(self) -> str:
        return self.__repr__()
