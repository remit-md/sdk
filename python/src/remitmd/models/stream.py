"""Stream model."""

from __future__ import annotations

from pydantic import BaseModel

from remitmd.models.common import StreamStatus


class Stream(BaseModel):
    """Active payment stream."""

    id: str
    payer: str
    payee: str
    rate_per_second: float
    max_duration: int
    max_total: float | None
    streamed: float
    claimable: float
    status: StreamStatus
    started_at: int
    ends_at: int | None
    chain: str
    created_at: int
    updated_at: int
