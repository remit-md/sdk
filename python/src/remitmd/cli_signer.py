"""CLI signer adapter for the remit CLI binary.

Delegates EIP-712 signing to the ``remit sign`` subprocess. The CLI
holds the encrypted keystore; this adapter only needs the binary on
PATH and the REMIT_KEY_PASSWORD env var set.

Usage::

    signer = await CliSigner.create()
    wallet = Wallet(signer=signer, chain="base")
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
from pathlib import Path

from remitmd.signer import Signer

# Default timeout for CLI subprocess calls (seconds).
_CLI_TIMEOUT = 10


class CliSigner(Signer):
    """Signer backed by the ``remit sign`` CLI command.

    - No key material in this process — signing happens in a subprocess.
    - Address is cached at construction time via ``remit address``.
    - sign_typed_data() pipes EIP-712 JSON to ``remit sign --eip712`` on stdin.
    - All errors are explicit — no silent fallbacks.
    """

    def __init__(self, cli_path: str = "remit") -> None:
        self._cli_path = cli_path
        self._address: str | None = None

    @classmethod
    async def create(cls, cli_path: str = "remit") -> CliSigner:
        """Create a CliSigner, fetching and caching the wallet address.

        Raises on CLI not found, keystore missing, or invalid address.
        """
        signer = cls(cli_path)
        proc = await asyncio.create_subprocess_exec(
            cli_path,
            "address",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=_CLI_TIMEOUT)
        if proc.returncode != 0:
            raise RuntimeError(f"CliSigner: failed to get address: {stderr.decode().strip()}")
        signer._address = stdout.decode().strip()
        if not signer._address.startswith("0x") or len(signer._address) != 42:
            raise RuntimeError(f"CliSigner: invalid address from CLI: {signer._address}")
        return signer

    def get_address(self) -> str:
        if not self._address:
            raise RuntimeError("CliSigner not initialized. Use: signer = await CliSigner.create()")
        return self._address

    async def sign_typed_data(
        self,
        domain: dict[str, object],
        types: dict[str, object],
        value: dict[str, object],
    ) -> str:
        payload = json.dumps({"domain": domain, "types": types, "message": value})
        proc = await asyncio.create_subprocess_exec(
            self._cli_path,
            "sign",
            "--eip712",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(payload.encode()), timeout=_CLI_TIMEOUT
        )
        if proc.returncode != 0:
            raise RuntimeError(f"CliSigner: signing failed: {stderr.decode().strip()}")
        sig = stdout.decode().strip()
        if not sig.startswith("0x") or len(sig) != 132:
            raise RuntimeError(f"CliSigner: invalid signature from CLI: {sig}")
        return sig

    @staticmethod
    def is_available(cli_path: str = "remit") -> bool:
        """Check conditions for CliSigner activation.

        1. CLI binary found on PATH
        2. ~/.remit/keys/default.meta exists (keychain, no password needed), OR
        3. ~/.remit/keys/default.enc exists AND REMIT_KEY_PASSWORD env var is set
        """
        if not shutil.which(cli_path):
            return False
        # Keychain path: .meta file exists (no password needed)
        meta = Path.home() / ".remit" / "keys" / "default.meta"
        if meta.exists():
            return True
        # Encrypted file path: .enc + password
        keystore = Path.home() / ".remit" / "keys" / "default.enc"
        if not keystore.exists():
            return False
        if not os.environ.get("REMIT_KEY_PASSWORD"):
            return False
        return True

    def __repr__(self) -> str:
        return f"CliSigner(address={self._address!r})"

    def __str__(self) -> str:
        return self.__repr__()
