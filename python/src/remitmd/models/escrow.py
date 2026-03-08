"""Escrow response model."""

from __future__ import annotations

from pydantic import BaseModel

from remitmd.models.common import EscrowStatus
from remitmd.models.invoice import Milestone


class Escrow(BaseModel):
    """Escrow state as returned by the API."""

    id: str
    invoice_id: str
    payer: str
    payee: str
    amount: float
    fee_bps: int
    status: EscrowStatus
    timeout_at: int
    milestones: list[Milestone] | None = None
    tx_hash: str | None = None
    chain: str
    created_at: int
    updated_at: int
