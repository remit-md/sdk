"""Integration test: OwsSigner with REAL open-wallet-standard FFI.

Skips automatically if OWS native binaries are not available (e.g. Windows).
In CI (Linux), OWS is installed as a pip step before this test runs.

What it tests:
  1. Create a wallet via OWS
  2. Construct OwsSigner from that wallet
  3. Sign EIP-712 typed data
  4. Verify the signature recovers to the wallet address (ecrecover)
"""

from __future__ import annotations

import time

import pytest
from eth_account.messages import encode_typed_data

# Try to load OWS — skip all tests if unavailable.
try:
    import ows  # type: ignore[import-untyped]

    OWS_AVAILABLE = True
except ImportError:
    OWS_AVAILABLE = False

pytestmark = pytest.mark.skipif(not OWS_AVAILABLE, reason="OWS not installed")

WALLET_NAME = f"remit-test-{int(time.time())}"


@pytest.fixture(scope="module", autouse=True)
def _ows_wallet():
    """Create a temporary OWS wallet for integration tests."""
    if not OWS_AVAILABLE:
        pytest.skip("OWS not installed")
    ows.create_wallet(WALLET_NAME)
    yield
    try:
        ows.delete_wallet(WALLET_NAME)
    except Exception:  # noqa: S110
        pass  # Best-effort cleanup


def _get_wallet_address() -> str:
    wallet_info = ows.get_wallet(WALLET_NAME)
    accounts = wallet_info.get("accounts", [])
    evm = next(
        (
            a
            for a in accounts
            if a.get("chain_id") == "evm" or a.get("chain_id", "").startswith("eip155:")
        ),
        None,
    )
    if evm is None:
        pytest.fail("No EVM account in created wallet")
    return evm["address"]


class TestOwsIntegration:
    def test_creates_signer_from_real_wallet(self) -> None:
        from remitmd.ows_signer import OwsSigner

        signer = OwsSigner(WALLET_NAME)
        assert signer.get_address() == _get_wallet_address()

    @pytest.mark.asyncio
    async def test_signs_eip712_and_recovers(self) -> None:
        from eth_account import Account

        from remitmd.ows_signer import OwsSigner

        address = _get_wallet_address()
        signer = OwsSigner(WALLET_NAME)

        domain = {
            "name": "USD Coin",
            "version": "2",
            "chainId": 84532,
            "verifyingContract": "0x2d846325766921935f37d5b4478196d3ef93707c",
        }
        types = {
            "Permit": [
                {"name": "owner", "type": "address"},
                {"name": "spender", "type": "address"},
                {"name": "value", "type": "uint256"},
                {"name": "nonce", "type": "uint256"},
                {"name": "deadline", "type": "uint256"},
            ],
        }
        deadline = int(time.time()) + 3600
        message = {
            "owner": address,
            "spender": "0x3120f396ff6a9afc5a9d92e28796082f1429e024",
            "value": "1000000",
            "nonce": 0,
            "deadline": deadline,
        }

        signature = await signer.sign_typed_data(domain, types, message)

        # Verify: 132 chars = "0x" + 130 hex
        assert len(signature) == 132, f"signature should be 132 chars, got {len(signature)}"
        assert signature.startswith("0x")

        # Ecrecover: verify the signature was made by the wallet address
        structured = encode_typed_data(
            domain_data=domain, message_types=types, message_data=message
        )
        recovered = Account.recover_message(structured, signature=bytes.fromhex(signature[2:]))
        assert recovered.lower() == address.lower(), (
            f"ecrecover mismatch: recovered {recovered}, expected {address}"
        )

    def test_wallet_with_ows_creates_working_wallet(self, monkeypatch: pytest.MonkeyPatch) -> None:
        from remitmd.wallet import Wallet

        address = _get_wallet_address()
        monkeypatch.setenv("OWS_WALLET_ID", WALLET_NAME)
        monkeypatch.delenv("REMITMD_KEY", raising=False)

        wallet = Wallet.with_ows()
        assert wallet.address == address
