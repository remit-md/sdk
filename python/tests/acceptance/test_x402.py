"""
Python SDK acceptance: x402 auto-payment via X402Client.

Spins up a local test server that returns 402 with a PAYMENT-REQUIRED header.
The X402Client auto-signs EIP-3009 and retries with PAYMENT-SIGNATURE.
We verify the payment signature is structurally valid and the retry succeeds.

On-chain settlement is tested separately in the API acceptance tests (C2).
This test focuses on the SDK client-side flow: 402 detection -> EIP-3009 signing -> retry.
"""

import base64
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread

import httpx
import pytest

from .conftest import API_URL, create_wallet, fund_wallet

pytestmark = pytest.mark.timeout(120)


class PaywallHandler(BaseHTTPRequestHandler):
    """Minimal x402 paywall: 402 without payment, 200 with valid payment."""

    # Set by the test before starting the server.
    usdc_address: str = ""
    router_address: str = ""
    expected_payer: str = ""

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        pass  # Silence request logs during tests

    def do_GET(self) -> None:
        payment_sig = self.headers.get("PAYMENT-SIGNATURE")

        if not payment_sig:
            # First request: return 402 with payment requirements
            payment_required = {
                "scheme": "exact",
                "network": "eip155:84532",
                "amount": "100000",  # $0.10 USDC
                "asset": self.usdc_address,
                "payTo": self.router_address,
                "maxTimeoutSeconds": 60,
                "resource": "/test-resource",
                "description": "x402 acceptance test",
                "mimeType": "text/plain",
            }
            encoded = base64.b64encode(json.dumps(payment_required).encode()).decode()
            self.send_response(402)
            self.send_header("Content-Type", "text/plain")
            self.send_header("PAYMENT-REQUIRED", encoded)
            self.end_headers()
            self.wfile.write(b"Payment Required")
            return

        # Second request: has PAYMENT-SIGNATURE — validate structure
        try:
            decoded = json.loads(base64.b64decode(payment_sig))

            if decoded["scheme"] != "exact":
                raise ValueError("wrong scheme")
            if decoded["network"] != "eip155:84532":
                raise ValueError("wrong network")
            if not decoded["payload"]["signature"].startswith("0x"):
                raise ValueError("bad signature")
            if decoded["payload"]["authorization"]["from"].lower() != self.expected_payer.lower():
                raise ValueError("wrong payer")
            if decoded["payload"]["authorization"]["value"] != "100000":
                raise ValueError("wrong amount")

            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"paid content")

        except Exception as e:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(f"Invalid payment: {e}".encode())


@pytest.mark.asyncio
async def test_x402_auto_pay() -> None:
    agent = await create_wallet()
    await fund_wallet(agent, 100)

    # Fetch contract addresses for the paywall header
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"{API_URL}/api/v1/contracts")
        resp.raise_for_status()
        contracts = resp.json()

    # Configure the paywall handler
    PaywallHandler.usdc_address = contracts["usdc"]
    PaywallHandler.router_address = contracts["router"]
    PaywallHandler.expected_payer = agent.address

    # Start local paywall server
    server = HTTPServer(("127.0.0.1", 0), PaywallHandler)
    port = server.server_address[1]
    server_url = f"http://127.0.0.1:{port}"
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        # x402_fetch auto-pays 402 and returns 200 with content
        response, last_payment = await agent.x402_fetch(
            f"{server_url}/test-resource",
            max_auto_pay_usdc=0.20,
        )

        assert response.status_code == 200, (
            f"should get 200 after auto-payment, got {response.status_code}"
        )
        assert response.text == "paid content", "should receive paid content"

        # Verify last_payment metadata (V2 fields)
        assert last_payment is not None, "last_payment should be set"
        assert last_payment["scheme"] == "exact"
        assert last_payment["amount"] == "100000"
        assert last_payment["resource"] == "/test-resource"
        assert last_payment["description"] == "x402 acceptance test"
        assert last_payment["mimeType"] == "text/plain"
    finally:
        server.shutdown()


@pytest.mark.asyncio
async def test_x402_rejects_above_limit() -> None:
    agent = await create_wallet()
    await fund_wallet(agent, 100)

    # Fetch contract addresses
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"{API_URL}/api/v1/contracts")
        resp.raise_for_status()
        contracts = resp.json()

    PaywallHandler.usdc_address = contracts["usdc"]
    PaywallHandler.router_address = contracts["router"]
    PaywallHandler.expected_payer = agent.address

    server = HTTPServer(("127.0.0.1", 0), PaywallHandler)
    port = server.server_address[1]
    server_url = f"http://127.0.0.1:{port}"
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        # The paywall asks for $0.10 but we set limit to $0.01 — should reject
        from remitmd.x402 import AllowanceExceededError

        with pytest.raises(AllowanceExceededError):
            await agent.x402_fetch(
                f"{server_url}/test-resource",
                max_auto_pay_usdc=0.01,
            )
    finally:
        server.shutdown()
