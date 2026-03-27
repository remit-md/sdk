"""LocalChain - wraps a local Anvil instance for real-EVM testing (<100ms per op).

Requires:
- `anvil` in PATH (install Foundry: https://getfoundry.sh)
- `REMITMD_API_URL=http://localhost:3000` (or the API running locally)
- Contracts deployed via `./scripts/deploy-local.sh`

Usage:
    chain = LocalChain.start()
    try:
        alice = chain.get_wallet(0)  # Anvil account 0
        bob = chain.get_wallet(1)
        tx = await alice.pay_direct(bob.address, 5.0)
    finally:
        chain.stop()

    # Or as a context manager:
    async with LocalChain.start() as chain:
        wallet = chain.get_wallet(0)
        ...
"""

from __future__ import annotations

import subprocess
import time
from typing import Any

import httpx

from remitmd.wallet import Wallet

# Anvil's deterministic test accounts (Foundry defaults)
_ANVIL_KEYS = [
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
    "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
    "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
    "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e",
    "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356",
    "0xdbda1821b80551c9d65939329250132c444d2025b0e9bb8f9f61d6b6e9a8e087",
    "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6",
]


class LocalChain:
    """
    Wrapper around a local Anvil process.

    Provides pre-funded Wallet instances using Anvil's default test accounts.
    """

    def __init__(self, port: int, api_url: str, process: subprocess.Popen[bytes] | None) -> None:
        self._port = port
        self._api_url = api_url
        self._process = process  # None if externally managed

    @classmethod
    def start(
        cls,
        port: int = 8545,
        api_url: str = "http://localhost:3000",
        block_time: int | None = None,
    ) -> LocalChain:
        """Start an Anvil process and return a LocalChain instance.

        If Anvil is already running on port, returns a LocalChain that wraps the
        existing process (useful when run via docker-compose).
        """
        # Check if anvil already running
        try:
            httpx.get(f"http://localhost:{port}", timeout=1.0)
            # Anvil returns 200 with a JSON-RPC style response
            return cls(port=port, api_url=api_url, process=None)
        except httpx.ConnectError:
            pass

        cmd = ["anvil", "--port", str(port), "--silent"]
        if block_time is not None:
            cmd += ["--block-time", str(block_time)]

        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)  # noqa: S603

        # Wait for Anvil to be ready (up to 5s)
        deadline = time.time() + 5.0
        while time.time() < deadline:
            try:
                httpx.get(f"http://localhost:{port}", timeout=0.5)
                break
            except httpx.ConnectError:
                time.sleep(0.1)
        else:
            proc.terminate()
            raise RuntimeError(f"Anvil failed to start on port {port}")

        return cls(port=port, api_url=api_url, process=proc)

    def get_wallet(self, index: int = 0, chain: str = "localhost") -> Wallet:
        """Return a Wallet loaded with Anvil's pre-funded test account at index."""
        if index >= len(_ANVIL_KEYS):
            raise IndexError(f"Anvil only has {len(_ANVIL_KEYS)} default accounts")
        return Wallet(
            private_key=_ANVIL_KEYS[index],
            chain=chain,
            testnet=True,
            api_url=self._api_url,
        )

    def advance_time(self, seconds: int) -> None:
        """Advance Anvil's block timestamp (evm_increaseTime + evm_mine)."""
        self._rpc("evm_increaseTime", [seconds])
        self._rpc("evm_mine", [])

    def mine(self, blocks: int = 1) -> None:
        """Mine N blocks instantly."""
        for _ in range(blocks):
            self._rpc("evm_mine", [])

    def snapshot(self) -> str:
        """Take an EVM snapshot. Returns snapshot ID (hex string)."""
        result = self._rpc("evm_snapshot", [])
        return str(result)

    def revert(self, snapshot_id: str) -> None:
        """Revert to a previously taken EVM snapshot."""
        self._rpc("evm_revert", [snapshot_id])

    def stop(self) -> None:
        """Stop the Anvil process if we started it."""
        if self._process is not None:
            self._process.terminate()
            self._process.wait(timeout=5)
            self._process = None

    def _rpc(self, method: str, params: list[Any]) -> Any:
        resp = httpx.post(
            f"http://localhost:{self._port}",
            json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
            timeout=5.0,
        )
        resp.raise_for_status()
        data = resp.json()
        if "error" in data:
            raise RuntimeError(f"RPC error: {data['error']}")
        return data.get("result")

    def __enter__(self) -> LocalChain:
        return self

    def __exit__(self, *_: Any) -> None:
        self.stop()
