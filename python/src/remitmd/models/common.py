"""Common enums and shared model types."""

from __future__ import annotations

from enum import Enum
from typing import Any

from pydantic import BaseModel


class ChainId(str, Enum):
    base = "base"
    base_sepolia = "base-sepolia"
    arbitrum = "arbitrum"
    arbitrum_sepolia = "arbitrum-sepolia"
    optimism = "optimism"
    optimism_sepolia = "optimism-sepolia"
    ethereum = "ethereum"
    sepolia = "sepolia"


class InvoiceStatus(str, Enum):
    pending = "pending"
    funded = "funded"
    active = "active"
    completed = "completed"
    cancelled = "cancelled"
    disputed = "disputed"
    failed = "failed"


class EscrowStatus(str, Enum):
    pending = "pending"
    funded = "funded"
    active = "active"
    completed = "completed"
    cancelled = "cancelled"
    disputed = "disputed"
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


class DisputeStatus(str, Enum):
    open = "open"
    under_review = "under_review"
    resolved = "resolved"
    closed = "closed"


class Transaction(BaseModel):
    """Result of a write operation."""

    invoice_id: str | None = None
    tx_hash: str | None = None
    chain: str
    status: str
    created_at: int  # unix timestamp


class WalletStatus(BaseModel):
    """Wallet status including balance and tier info."""

    address: str
    chain: str
    usdc_balance: float
    tier: str
    monthly_volume: float
    fee_rate_bps: int  # basis points


class Reputation(BaseModel):
    """On-chain reputation profile."""

    address: str
    score: float
    total_paid: float
    total_received: float
    escrows_completed: int
    escrows_disputed: int
    dispute_rate: float
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
