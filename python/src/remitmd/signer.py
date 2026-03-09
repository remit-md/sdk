"""Pluggable signer interface and PrivateKeySigner implementation.

Keeping key material in a Signer subclass (rather than on Wallet directly)
means the wallet object itself never holds a raw private key reference.
"""

from __future__ import annotations

from abc import ABC, abstractmethod

from eth_account import Account
from eth_account.messages import encode_typed_data


class Signer(ABC):
    """Abstract signing interface. Implement this for KMS, hardware wallets, etc."""

    @abstractmethod
    async def sign_typed_data(
        self,
        domain: dict[str, object],
        types: dict[str, object],
        value: dict[str, object],
    ) -> str:
        """Return the 0x-prefixed hex signature."""
        ...

    @abstractmethod
    def get_address(self) -> str:
        """Return the checksummed Ethereum address for this signer."""
        ...


class PrivateKeySigner(Signer):
    """Signs EIP-712 typed data with a raw secp256k1 private key.

    The private key is held in an eth_account LocalAccount object and is
    never exposed as a plain string after construction.
    """

    def __init__(self, private_key: str) -> None:
        # eth_account normalises the key and raises on invalid input
        self._account = Account.from_key(private_key)

    async def sign_typed_data(
        self,
        domain: dict[str, object],
        types: dict[str, object],
        value: dict[str, object],
    ) -> str:
        structured = encode_typed_data(domain_data=domain, message_types=types, message_data=value)
        signed = self._account.sign_message(structured)
        return str(signed.signature.hex())

    def get_address(self) -> str:
        return str(self._account.address)

    # Never expose key material
    def __repr__(self) -> str:
        return f"PrivateKeySigner(address={self.get_address()})"

    def __str__(self) -> str:
        return self.__repr__()
