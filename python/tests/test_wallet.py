"""Tests for Wallet construction, signer isolation, and utility methods."""

import pytest
from remitmd.signer import PrivateKeySigner
from remitmd.wallet import Wallet


# ─── Construction ─────────────────────────────────────────────────────────────

def test_wallet_from_private_key():
    key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    wallet = Wallet(private_key=key, chain="localhost", testnet=True)
    assert wallet.address == "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"


def test_wallet_from_signer():
    key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    signer = PrivateKeySigner(key)
    wallet = Wallet(signer=signer, chain="localhost", testnet=True)
    assert wallet.address == "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"


def test_wallet_create_generates_unique_address():
    w1 = Wallet.create(chain="localhost", testnet=True)
    w2 = Wallet.create(chain="localhost", testnet=True)
    assert w1.address != w2.address


def test_wallet_from_env(monkeypatch):
    key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    monkeypatch.setenv("REMITMD_KEY", key)
    monkeypatch.setenv("REMITMD_CHAIN", "localhost")
    monkeypatch.setenv("REMITMD_TESTNET", "true")
    wallet = Wallet.from_env()
    assert wallet.address == "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    assert wallet.chain == "localhost"
    assert wallet.testnet is True


def test_wallet_from_env_missing_key_raises(monkeypatch):
    monkeypatch.delenv("REMITMD_KEY", raising=False)
    with pytest.raises(EnvironmentError, match="REMITMD_KEY"):
        Wallet.from_env()


def test_wallet_requires_key_or_signer():
    with pytest.raises(ValueError, match="Provide either"):
        Wallet(chain="localhost", testnet=True)


def test_wallet_key_and_signer_exclusive():
    key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    signer = PrivateKeySigner(key)
    with pytest.raises(ValueError, match="not both"):
        Wallet(private_key=key, signer=signer, chain="localhost", testnet=True)


# ─── Security: key never exposed ──────────────────────────────────────────────

def test_wallet_repr_does_not_expose_key():
    key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    wallet = Wallet(private_key=key, chain="localhost", testnet=True)
    assert key not in repr(wallet)
    assert key not in str(wallet)


def test_wallet_cannot_be_pickled():
    import pickle
    key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    wallet = Wallet(private_key=key, chain="localhost", testnet=True)
    with pytest.raises(TypeError, match="pickled"):
        pickle.dumps(wallet)


def test_signer_repr_does_not_expose_key():
    key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    signer = PrivateKeySigner(key)
    assert key not in repr(signer)
    assert key not in str(signer)
