"""Dispute model."""

from __future__ import annotations

from pydantic import BaseModel

from remitmd.models.common import DisputeStatus


class Dispute(BaseModel):
    """Filed payment dispute."""

    id: str
    invoice_id: str
    filer: str
    reason: str
    details: str
    evidence_uri: str
    response: str | None
    status: DisputeStatus
    resolution: str | None
    created_at: int
    resolved_at: int | None
