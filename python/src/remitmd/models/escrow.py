"""Escrow response model."""

from __future__ import annotations

from pydantic import BaseModel

from remitmd.models.common import EscrowStatus


class Escrow(BaseModel):
    """Escrow state as returned by the API.

    Field names and types match the server's ``models::escrow::Escrow`` struct.
    Datetimes arrive as RFC-3339 strings from the Rust/serde layer.
    """

    invoice_id: str
    chain: str
    tx_hash: str
    status: EscrowStatus | str
    payer: str
    payee: str
    amount: float
    fee: float
    timeout: str  # RFC-3339
    claim_started: bool = False
    claim_started_at: str | None = None
    evidence_hash: str | None = None
    evidence_uri: str | None = None
    released_at: str | None = None
    cancelled_at: str | None = None
    timed_out_at: str | None = None
    created_at: str  # RFC-3339
    updated_at: str  # RFC-3339
