"""Invoice models."""

from __future__ import annotations

from pydantic import BaseModel, field_validator

from remitmd.models.common import InvoiceStatus


class Split(BaseModel):
    """Fee split recipient."""

    address: str
    bps: int  # basis points, must sum to 10000 across all splits


class Milestone(BaseModel):
    """Escrow milestone."""

    description: str
    amount: float
    evidence_uri: str | None = None
    released_at: int | None = None


class Invoice(BaseModel):
    """
    Payment invoice — the core data structure passed to wallet.pay().

    Represents the full payment intent before it hits the chain.
    """

    id: str | None = None  # set by server after creation
    to: str  # recipient wallet address
    amount: float  # total in USD
    memo: str = ""
    chain: str = "base"
    payment_model: str = "escrow"  # escrow | tab | stream | bounty | deposit | direct
    timeout: int = 86400  # seconds
    milestones: list[Milestone] | None = None
    splits: list[Split] | None = None
    metadata: dict[str, str] | None = None
    status: InvoiceStatus = InvoiceStatus.pending
    created_at: int | None = None

    @field_validator("amount")
    @classmethod
    def amount_must_be_positive(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("amount must be positive")
        return v

    @field_validator("splits")
    @classmethod
    def splits_must_sum_to_10000(cls, v: list[Split] | None) -> list[Split] | None:
        if v is not None:
            total = sum(s.bps for s in v)
            if total != 10000:
                raise ValueError(f"splits bps must sum to 10000, got {total}")
        return v
