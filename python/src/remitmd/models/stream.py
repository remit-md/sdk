"""Stream model."""

from __future__ import annotations

from pydantic import AliasChoices, BaseModel, ConfigDict, Field

from remitmd.models.common import StreamStatus


class Stream(BaseModel):
    """Active payment stream."""

    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    id: str
    payer: str
    payee: str
    rate_per_second: float
    max_duration: int | None = None
    max_total: float | None = None
    streamed: float = Field(
        default=0.0,
        validation_alias=AliasChoices("streamed", "withdrawn"),
    )
    claimable: float = 0.0
    status: StreamStatus
    started_at: int | str = 0
    ends_at: int | str | None = Field(
        default=None,
        validation_alias=AliasChoices("ends_at", "closed_at"),
    )
    chain: str = ""
    created_at: int | str = 0
    updated_at: int | str = 0
