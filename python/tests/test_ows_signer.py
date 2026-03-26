"""Tests for OwsSigner — OWS adapter with mocked FFI module."""

from __future__ import annotations

import json

import pytest

from remitmd.ows_signer import OwsSigner
from remitmd.wallet import Wallet

# ─── Mock OWS Module ──────────────────────────────────────────────────────────

MOCK_ADDRESS = "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD50"
MOCK_WALLET_ID = "remit-test-agent"

# r||s (128 hex chars, no v) — OWS returns this when recovery_id is separate.
MOCK_SIG_RS = "a" * 64 + "b" * 64  # 128 hex

# r||s||v (130 hex chars) — OWS returns this when v is already appended.
MOCK_SIG_RSV = "a" * 64 + "b" * 64 + "1b"  # 130 hex


class MockOws:
    """Mock of the ``ows`` module for unit testing."""

    def __init__(
        self,
        signature: str = MOCK_SIG_RS,
        recovery_id: int | None = 0,
        accounts: list[dict[str, str]] | None = None,
    ) -> None:
        self._signature = signature
        self._recovery_id = recovery_id
        self._accounts = accounts or [
            {"chain_id": "evm", "address": MOCK_ADDRESS, "derivation_path": "m/44'/60'/0'/0/0"},
        ]
        self.sign_calls: list[dict[str, object]] = []

    def get_wallet(self, name_or_id: str, vault_path_opt: str | None = None) -> dict[str, object]:
        return {
            "id": f"uuid-{name_or_id}",
            "name": name_or_id,
            "accounts": self._accounts,
            "created_at": "2026-01-01T00:00:00Z",
        }

    def sign_typed_data(
        self,
        wallet: str,
        chain: str,
        typed_data_json: str,
        passphrase: str | None = None,
        index: int | None = None,
        vault_path_opt: str | None = None,
    ) -> dict[str, object]:
        self.sign_calls.append(
            {
                "wallet": wallet,
                "chain": chain,
                "json": typed_data_json,
                "passphrase": passphrase,
            }
        )
        return {
            "signature": self._signature,
            "recovery_id": self._recovery_id,
        }


# ─── OwsSigner construction ──────────────────────────────────────────────────


class TestOwsSignerCreate:
    def test_constructs_with_mock(self) -> None:
        signer = OwsSigner(MOCK_WALLET_ID, _ows_module=MockOws())
        assert signer.get_address() == MOCK_ADDRESS

    def test_caches_address(self) -> None:
        signer = OwsSigner(MOCK_WALLET_ID, _ows_module=MockOws())
        assert signer.get_address() == MOCK_ADDRESS
        assert signer.get_address() == MOCK_ADDRESS  # Same value every time

    def test_finds_evm_account_by_chain_id_evm(self) -> None:
        mock = MockOws(
            accounts=[
                {
                    "chain_id": "solana",
                    "address": "SolAddr",
                    "derivation_path": "m/44'/501'/0'/0/0",
                },
                {"chain_id": "evm", "address": MOCK_ADDRESS, "derivation_path": "m/44'/60'/0'/0/0"},
            ]
        )
        signer = OwsSigner(MOCK_WALLET_ID, _ows_module=mock)
        assert signer.get_address() == MOCK_ADDRESS

    def test_finds_evm_account_by_eip155_prefix(self) -> None:
        mock = MockOws(
            accounts=[
                {
                    "chain_id": "eip155:8453",
                    "address": MOCK_ADDRESS,
                    "derivation_path": "m/44'/60'/0'/0/0",
                },
            ]
        )
        signer = OwsSigner(MOCK_WALLET_ID, _ows_module=mock)
        assert signer.get_address() == MOCK_ADDRESS

    def test_throws_when_no_evm_account(self) -> None:
        mock = MockOws(
            accounts=[
                {"chain_id": "solana", "address": "SolAddr", "derivation_path": ""},
            ]
        )
        with pytest.raises(ValueError, match="No EVM account found"):
            OwsSigner(MOCK_WALLET_ID, _ows_module=mock)

    def test_throws_when_ows_not_installed(self) -> None:
        import sys
        from unittest.mock import patch

        # Simulate OWS not installed by blocking the import via sys.modules.
        with patch.dict(sys.modules, {"ows": None}):
            with pytest.raises(ImportError, match="open-wallet-standard is not installed"):
                OwsSigner(MOCK_WALLET_ID)


# ─── signTypedData ────────────────────────────────────────────────────────────


class TestOwsSignerSignTypedData:
    @pytest.mark.asyncio
    async def test_builds_correct_eip712_json(self) -> None:
        mock = MockOws()
        signer = OwsSigner(MOCK_WALLET_ID, _ows_module=mock)

        await signer.sign_typed_data(
            {"name": "USD Coin", "version": "2", "chainId": 8453, "verifyingContract": "0xUSDC"},
            {
                "Permit": [
                    {"name": "owner", "type": "address"},
                    {"name": "value", "type": "uint256"},
                ]
            },
            {"owner": "0xABC", "value": "1000000"},
        )

        assert len(mock.sign_calls) == 1
        parsed = json.loads(str(mock.sign_calls[0]["json"]))

        # EIP712Domain should be injected
        assert "EIP712Domain" in parsed["types"]
        assert len(parsed["types"]["EIP712Domain"]) == 4

        # primaryType should be derived
        assert parsed["primaryType"] == "Permit"

        # domain should be passed through
        assert parsed["domain"]["name"] == "USD Coin"
        assert parsed["domain"]["chainId"] == 8453

        # message should be the value
        assert parsed["message"]["owner"] == "0xABC"

    @pytest.mark.asyncio
    async def test_derives_primary_type(self) -> None:
        mock = MockOws()
        signer = OwsSigner(MOCK_WALLET_ID, _ows_module=mock)

        await signer.sign_typed_data(
            {"name": "remit.md", "version": "0.1"},
            {"APIRequest": [{"name": "method", "type": "string"}]},
            {"method": "POST"},
        )

        parsed = json.loads(str(mock.sign_calls[0]["json"]))
        assert parsed["primaryType"] == "APIRequest"

    @pytest.mark.asyncio
    async def test_builds_eip712_domain_from_present_fields_only(self) -> None:
        mock = MockOws()
        signer = OwsSigner(MOCK_WALLET_ID, _ows_module=mock)

        # Domain with only name and version (no chainId, no verifyingContract)
        await signer.sign_typed_data(
            {"name": "Test", "version": "1"},
            {"Msg": [{"name": "data", "type": "string"}]},
            {"data": "hello"},
        )

        parsed = json.loads(str(mock.sign_calls[0]["json"]))
        assert len(parsed["types"]["EIP712Domain"]) == 2
        names = [f["name"] for f in parsed["types"]["EIP712Domain"]]
        assert names == ["name", "version"]

    @pytest.mark.asyncio
    async def test_always_passes_evm_chain(self) -> None:
        mock = MockOws()
        signer = OwsSigner(MOCK_WALLET_ID, chain="base-sepolia", _ows_module=mock)

        await signer.sign_typed_data(
            {"name": "Test", "version": "1"},
            {"Msg": [{"name": "x", "type": "uint256"}]},
            {"x": 42},
        )

        assert mock.sign_calls[0]["chain"] == "evm"

    @pytest.mark.asyncio
    async def test_passes_api_key_as_passphrase(self) -> None:
        mock = MockOws()
        signer = OwsSigner(MOCK_WALLET_ID, ows_api_key="ows_key_test123", _ows_module=mock)

        await signer.sign_typed_data(
            {"name": "T", "version": "1"},
            {"M": [{"name": "x", "type": "uint256"}]},
            {"x": 1},
        )

        assert mock.sign_calls[0]["passphrase"] == "ows_key_test123"  # noqa: S105

    @pytest.mark.asyncio
    async def test_api_key_not_in_json_payload(self) -> None:
        mock = MockOws()
        signer = OwsSigner(MOCK_WALLET_ID, ows_api_key="ows_key_secret", _ows_module=mock)

        await signer.sign_typed_data(
            {"name": "T", "version": "1"},
            {"M": [{"name": "x", "type": "uint256"}]},
            {"x": 1},
        )

        assert "ows_key_secret" not in str(mock.sign_calls[0]["json"])


# ─── Signature concatenation ──────────────────────────────────────────────────


class TestOwsSignerSigConcat:
    @pytest.mark.asyncio
    async def test_appends_v27_for_recovery_id_0(self) -> None:
        signer = OwsSigner(
            MOCK_WALLET_ID, _ows_module=MockOws(signature=MOCK_SIG_RS, recovery_id=0)
        )

        sig = await signer.sign_typed_data(
            {"name": "T", "version": "1"},
            {"M": [{"name": "x", "type": "uint256"}]},
            {"x": 1},
        )

        assert len(sig) == 132  # "0x" + 130 hex
        assert sig.startswith("0x")
        assert sig[-2:] == "1b"  # v=27 = 0x1b

    @pytest.mark.asyncio
    async def test_appends_v28_for_recovery_id_1(self) -> None:
        signer = OwsSigner(
            MOCK_WALLET_ID, _ows_module=MockOws(signature=MOCK_SIG_RS, recovery_id=1)
        )

        sig = await signer.sign_typed_data(
            {"name": "T", "version": "1"},
            {"M": [{"name": "x", "type": "uint256"}]},
            {"x": 1},
        )

        assert sig[-2:] == "1c"  # v=28 = 0x1c

    @pytest.mark.asyncio
    async def test_returns_130_char_rsv_as_is(self) -> None:
        signer = OwsSigner(MOCK_WALLET_ID, _ows_module=MockOws(signature=MOCK_SIG_RSV))

        sig = await signer.sign_typed_data(
            {"name": "T", "version": "1"},
            {"M": [{"name": "x", "type": "uint256"}]},
            {"x": 1},
        )

        assert len(sig) == 132
        assert sig == f"0x{MOCK_SIG_RSV}"

    @pytest.mark.asyncio
    async def test_handles_0x_prefixed_signature(self) -> None:
        signer = OwsSigner(
            MOCK_WALLET_ID, _ows_module=MockOws(signature=f"0x{MOCK_SIG_RS}", recovery_id=0)
        )

        sig = await signer.sign_typed_data(
            {"name": "T", "version": "1"},
            {"M": [{"name": "x", "type": "uint256"}]},
            {"x": 1},
        )

        assert len(sig) == 132
        assert sig.startswith("0x")

    @pytest.mark.asyncio
    async def test_defaults_recovery_id_to_0(self) -> None:
        signer = OwsSigner(
            MOCK_WALLET_ID, _ows_module=MockOws(signature=MOCK_SIG_RS, recovery_id=None)
        )

        sig = await signer.sign_typed_data(
            {"name": "T", "version": "1"},
            {"M": [{"name": "x", "type": "uint256"}]},
            {"x": 1},
        )

        assert sig[-2:] == "1b"  # v=27


# ─── Security / serialization ─────────────────────────────────────────────────


class TestOwsSignerSecurity:
    def test_repr_shows_address_and_wallet(self) -> None:
        signer = OwsSigner(MOCK_WALLET_ID, ows_api_key="ows_key_secret", _ows_module=MockOws())
        r = repr(signer)
        assert MOCK_ADDRESS in r
        assert MOCK_WALLET_ID in r
        assert "ows_key_secret" not in r

    def test_str_does_not_expose_api_key(self) -> None:
        signer = OwsSigner(MOCK_WALLET_ID, ows_api_key="ows_key_secret", _ows_module=MockOws())
        assert "ows_key_secret" not in str(signer)


# ─── Wallet.with_ows() ────────────────────────────────────────────────────────


class TestWalletWithOws:
    def test_throws_when_neither_ows_nor_key(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv("OWS_WALLET_ID", raising=False)
        monkeypatch.delenv("REMITMD_KEY", raising=False)
        with pytest.raises(ValueError, match="OWS_WALLET_ID or REMITMD_KEY"):
            Wallet.with_ows()

    def test_falls_back_to_remitmd_key(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv("OWS_WALLET_ID", raising=False)
        monkeypatch.setenv(
            "REMITMD_KEY", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
        )
        wallet = Wallet.with_ows()
        assert wallet.address.lower() == "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

    def test_uses_ows_when_wallet_id_set(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("OWS_WALLET_ID", MOCK_WALLET_ID)
        monkeypatch.delenv("REMITMD_KEY", raising=False)
        wallet = Wallet.with_ows(_ows_module=MockOws())
        assert wallet.address == MOCK_ADDRESS

    def test_from_env_throws_helpful_error_when_ows_set(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("OWS_WALLET_ID", "remit-test")
        monkeypatch.delenv("REMITMD_KEY", raising=False)
        with pytest.raises(OSError, match="with_ows"):
            Wallet.from_env()
