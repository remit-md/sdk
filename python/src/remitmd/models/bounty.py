"""Bounty and BountySubmission models."""

from __future__ import annotations

from pydantic import BaseModel

from remitmd.models.common import BountyStatus


class BountySubmission(BaseModel):
    """A single submission against a bounty."""

    id: str
    bounty_id: str
    submitter: str
    evidence_uri: str
    status: str  # pending | accepted | rejected
    submitted_at: int


class Bounty(BaseModel):
    """Open or awarded bounty."""

    id: str
    poster: str
    amount: float
    task: str
    deadline: int
    validation: str  # poster | auto
    max_attempts: int
    attempts: int
    winner: str | None
    status: BountyStatus
    submissions: list[BountySubmission] | None = None
    chain: str
    created_at: int
    updated_at: int
