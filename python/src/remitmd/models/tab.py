"""Tab and TabCharge models."""

from __future__ import annotations

from pydantic import BaseModel

from remitmd.models.common import TabStatus


class Tab(BaseModel):
    """Metered payment tab as returned by the API.

    Field names match the server's ``models::tab::Tab`` struct.
    """

    id: str
    chain: str
    payer: str
    provider: str
    limit_amount: float
    per_unit: float
    total_charged: float
    call_count: int
    status: TabStatus | str
    expiry: str  # RFC-3339
    tx_hash: str
    closed_tx_hash: str | None = None
    created_at: str  # RFC-3339
    updated_at: str  # RFC-3339


class TabCharge(BaseModel):
    """A single charge event on a tab."""

    id: int
    tab_id: str
    amount: float
    cumulative: float
    call_count: int
    provider_sig: str
    charged_at: str  # RFC-3339
