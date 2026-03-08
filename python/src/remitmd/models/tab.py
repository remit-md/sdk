"""Tab and TabCharge models."""

from __future__ import annotations

from pydantic import BaseModel

from remitmd.models.common import TabStatus


class Tab(BaseModel):
    """Open metered payment tab."""

    id: str
    payer: str
    payee: str
    limit: float
    per_unit: float
    used: float
    remaining: float
    expires_at: int
    status: TabStatus
    chain: str
    created_at: int
    updated_at: int


class TabCharge(BaseModel):
    """A single charge event on a tab."""

    id: str
    tab_id: str
    units: float
    amount: float
    memo: str
    created_at: int
