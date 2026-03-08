"""Deposit model."""

from __future__ import annotations

from pydantic import BaseModel

from remitmd.models.common import DepositStatus


class Deposit(BaseModel):
    """Refundable security deposit."""

    id: str
    payer: str
    payee: str
    amount: float
    expires_at: int
    status: DepositStatus
    tx_hash: str | None
    chain: str
    created_at: int
    updated_at: int
