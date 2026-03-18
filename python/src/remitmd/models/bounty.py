"""Bounty and BountySubmission models."""

from __future__ import annotations

from pydantic import AliasChoices, BaseModel, ConfigDict, Field

from remitmd.models.common import BountyStatus


class BountySubmission(BaseModel):
    """A single submission against a bounty."""

    model_config = ConfigDict(extra="ignore")

    id: str
    bounty_id: str = ""
    submitter: str = ""
    evidence_uri: str = Field(
        default="",
        validation_alias=AliasChoices("evidence_uri", "evidence_hash"),
    )
    status: str = "pending"
    submitted_at: int | str = 0


class Bounty(BaseModel):
    """Open or awarded bounty."""

    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    id: str
    poster: str
    amount: float
    task: str = Field(
        default="",
        validation_alias=AliasChoices("task", "task_description"),
    )
    deadline: int | str = 0
    validation: str | None = None
    max_attempts: int = 10
    attempts: int = Field(
        default=0,
        validation_alias=AliasChoices("attempts", "attempt_count"),
    )
    winner: str | None = None
    status: BountyStatus
    submissions: list[BountySubmission] | None = None
    chain: str = ""
    created_at: int | str = 0
    updated_at: int | str = 0
