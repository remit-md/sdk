"""Common enums and shared model types."""

from __future__ import annotations

from enum import Enum
from typing import Any

from pydantic import BaseModel


class ChainId(str, Enum):
    base = "base"
    base_sepolia = "base-sepolia"


class InvoiceStatus(str, Enum):
    pending = "pending"
    funded = "funded"
    active = "active"
    completed = "completed"
    cancelled = "cancelled"
    failed = "failed"


class EscrowStatus(str, Enum):
    pending = "pending"
    funded = "funded"
    active = "active"
    completed = "completed"
    cancelled = "cancelled"
    failed = "failed"


class TabStatus(str, Enum):
    open = "open"
    closed = "closed"
    expired = "expired"
    suspended = "suspended"


class StreamStatus(str, Enum):
    active = "active"
    paused = "paused"
    closed = "closed"
    completed = "completed"
    cancelled = "cancelled"


class BountyStatus(str, Enum):
    open = "open"
    closed = "closed"
    awarded = "awarded"
    expired = "expired"
    cancelled = "cancelled"


class DepositStatus(str, Enum):
    locked = "locked"
    returned = "returned"
    forfeited = "forfeited"
    expired = "expired"


class Transaction(BaseModel):
    """Result of a write operation.

    Fields are optional because different server endpoints return different
    subsets (e.g. DirectPaymentResponse has no ``chain``/``created_at``,
    FaucetResponse has only ``tx_hash``).
    """

    invoice_id: str | None = None
    tx_hash: str | None = None
    chain: str | None = None
    status: str | None = None
    created_at: str | int | None = None  # ISO-8601 string or unix timestamp


class WalletStatus(BaseModel):
    """Wallet status as returned by the server."""

    wallet: str
    balance: str = "0.00"
    tier: str
    monthly_volume: float
    fee_rate_bps: int  # basis points
    active_escrows: int = 0
    active_tabs: int = 0
    active_streams: int = 0
    permit_nonce: int | None = None


class LinkResponse(BaseModel):
    """One-time operator link returned by create_fund_link / create_withdraw_link."""

    url: str
    token: str
    expires_at: str
    wallet_address: str


class Reputation(BaseModel):
    """On-chain reputation profile."""

    address: str
    score: float
    total_paid: float
    total_received: float
    escrows_completed: int
    member_since: int


class Event(BaseModel):
    """Webhook / polling event."""

    id: str
    type: str
    chain: str
    wallet: str
    payload: dict[str, Any]
    created_at: int


class Webhook(BaseModel):
    """Registered webhook endpoint."""

    id: str
    wallet: str
    url: str
    events: list[str]
    chains: list[str]
    active: bool
    created_at: int
