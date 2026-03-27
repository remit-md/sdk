"""Tests for the HTTP signer adapter."""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import ClassVar

import pytest

from remitmd.http_signer import HttpSigner

# ── Mock signer server ──────────────────────────────────────────────────────

MOCK_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
MOCK_SIGNATURE = "0x" + "ab" * 32 + "cd" * 32 + "1b"
VALID_TOKEN = "rmit_sk_" + "a1" * 32


class MockSignerHandler(BaseHTTPRequestHandler):
    """HTTP handler that mimics the local signer server."""

    # Class-level overrides for specific paths
    overrides: ClassVar[dict[str, tuple[int, dict[str, object]]]] = {}

    def log_message(self, format: str, *args: object) -> None:
        pass  # Suppress logs

    def _check_auth(self) -> bool:
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            self._respond(401, {"error": "unauthorized"})
            return False
        token = auth[7:]
        if token != VALID_TOKEN:
            self._respond(401, {"error": "unauthorized"})
            return False
        return True

    def _respond(self, status: int, body: dict[str, object]) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_GET(self) -> None:
        path = self.path

        if path in self.overrides:
            status, body = self.overrides[path]
            self._respond(status, body)
            return

        if path == "/health":
            self._respond(200, {"ok": True})
            return

        if not self._check_auth():
            return

        if path == "/address":
            self._respond(200, {"address": MOCK_ADDRESS})
        else:
            self._respond(404, {"error": "not_found"})

    def do_POST(self) -> None:
        path = self.path

        if path in self.overrides:
            status, body = self.overrides[path]
            self._respond(status, body)
            return

        if not self._check_auth():
            return

        if path == "/sign/typed-data":
            self._respond(200, {"signature": MOCK_SIGNATURE})
        else:
            self._respond(404, {"error": "not_found"})


def start_mock_server(
    overrides: dict[str, tuple[int, dict[str, object]]] | None = None,
) -> tuple[HTTPServer, str]:
    """Start a mock signer server on a random port."""

    class Handler(MockSignerHandler):
        pass

    Handler.overrides = overrides or {}
    server = HTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, f"http://127.0.0.1:{port}"


# ── Fixtures ─────────────────────────────────────────────────────────────────


@pytest.fixture()
def mock_server():
    server, url = start_mock_server()
    yield url
    server.shutdown()


@pytest.fixture()
def policy_denied_server():
    server, url = start_mock_server(
        overrides={
            "/sign/typed-data": (403, {"error": "policy_denied", "reason": "chain not allowed"}),
        }
    )
    yield url
    server.shutdown()


@pytest.fixture()
def error_server():
    server, url = start_mock_server(
        overrides={
            "/sign/typed-data": (500, {"error": "internal_error"}),
        }
    )
    yield url
    server.shutdown()


@pytest.fixture()
def malformed_server():
    server, url = start_mock_server(
        overrides={
            "/sign/typed-data": (200, {"not_signature": True}),
        }
    )
    yield url
    server.shutdown()


# ── Tests ────────────────────────────────────────────────────────────────────


class TestHttpSignerCreate:
    @pytest.mark.anyio()
    async def test_create_fetches_address(self, mock_server: str) -> None:
        signer = await HttpSigner.create(mock_server, VALID_TOKEN)
        assert signer.get_address() == MOCK_ADDRESS

    @pytest.mark.anyio()
    async def test_create_bad_token(self, mock_server: str) -> None:
        with pytest.raises(PermissionError, match="unauthorized"):
            await HttpSigner.create(mock_server, "bad_token")

    @pytest.mark.anyio()
    async def test_create_unreachable(self) -> None:
        with pytest.raises(ConnectionError, match="cannot reach"):
            await HttpSigner.create("http://127.0.0.1:1", VALID_TOKEN)


class TestHttpSignerSign:
    @pytest.mark.anyio()
    async def test_sign_returns_signature(self, mock_server: str) -> None:
        signer = await HttpSigner.create(mock_server, VALID_TOKEN)
        sig = await signer.sign_typed_data(
            {"name": "Test", "version": "1"},
            {"Test": [{"name": "value", "type": "uint256"}]},
            {"value": 42},
        )
        assert sig == MOCK_SIGNATURE

    @pytest.mark.anyio()
    async def test_sign_policy_denied(self, policy_denied_server: str) -> None:
        signer = await HttpSigner.create(policy_denied_server, VALID_TOKEN)
        with pytest.raises(PermissionError, match="policy denied"):
            await signer.sign_typed_data({}, {}, {})

    @pytest.mark.anyio()
    async def test_sign_server_error(self, error_server: str) -> None:
        signer = await HttpSigner.create(error_server, VALID_TOKEN)
        with pytest.raises(RuntimeError, match="500"):
            await signer.sign_typed_data({}, {}, {})

    @pytest.mark.anyio()
    async def test_sign_malformed_response(self, malformed_server: str) -> None:
        signer = await HttpSigner.create(malformed_server, VALID_TOKEN)
        with pytest.raises(RuntimeError, match="no signature"):
            await signer.sign_typed_data({}, {}, {})


class TestHttpSignerNoLeakage:
    @pytest.mark.anyio()
    async def test_repr_no_token(self, mock_server: str) -> None:
        signer = await HttpSigner.create(mock_server, VALID_TOKEN)
        r = repr(signer)
        assert VALID_TOKEN not in r
        assert MOCK_ADDRESS in r

    @pytest.mark.anyio()
    async def test_str_no_token(self, mock_server: str) -> None:
        signer = await HttpSigner.create(mock_server, VALID_TOKEN)
        s = str(signer)
        assert VALID_TOKEN not in s


class TestHttpSignerNotInitialized:
    def test_get_address_before_create(self) -> None:
        signer = HttpSigner("http://localhost:7402", "token")
        with pytest.raises(RuntimeError, match="not initialized"):
            signer.get_address()
