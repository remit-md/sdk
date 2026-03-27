"""Tests for the CLI signer adapter."""

from __future__ import annotations

import os

import pytest

from remitmd.cli_signer import CliSigner


class TestCliSignerIsAvailable:
    """Test the static is_available() method."""

    def test_returns_false_when_no_keystore(self) -> None:
        # Default keystore path doesn't exist in CI
        assert CliSigner.is_available() is False

    def test_returns_false_when_no_password(self) -> None:
        old = os.environ.pop("REMIT_KEY_PASSWORD", None)
        try:
            assert CliSigner.is_available() is False
        finally:
            if old is not None:
                os.environ["REMIT_KEY_PASSWORD"] = old

    def test_returns_false_when_cli_not_found(self) -> None:
        assert CliSigner.is_available("nonexistent-remit-binary-xyz") is False


class TestCliSignerCreate:
    """Test the async create() factory."""

    @pytest.mark.asyncio
    async def test_create_fails_when_cli_not_found(self) -> None:
        with pytest.raises((FileNotFoundError, RuntimeError)):
            await CliSigner.create("nonexistent-remit-binary-xyz")

    def test_get_address_fails_when_not_initialized(self) -> None:
        signer = CliSigner.__new__(CliSigner)
        signer._address = None
        with pytest.raises(RuntimeError, match="not initialized"):
            signer.get_address()


class TestCliSignerRepr:
    """Test repr/str don't leak sensitive data."""

    def test_repr_shows_address(self) -> None:
        signer = CliSigner.__new__(CliSigner)
        signer._cli_path = "remit"
        signer._address = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
        r = repr(signer)
        assert "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" in r
        assert "key" not in r.lower()

    def test_repr_handles_none_address(self) -> None:
        signer = CliSigner.__new__(CliSigner)
        signer._cli_path = "remit"
        signer._address = None
        r = repr(signer)
        assert "None" in r
