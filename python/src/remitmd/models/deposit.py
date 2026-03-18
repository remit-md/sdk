"""Deposit model."""

from __future__ import annotations

from pydantic import AliasChoices, BaseModel, ConfigDict, Field

from remitmd.models.common import DepositStatus


class Deposit(BaseModel):
    """Refundable security deposit."""

    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    id: str
    payer: str = Field(
        default="",
        validation_alias=AliasChoices("payer", "depositor"),
    )
    payee: str = Field(
        default="",
        validation_alias=AliasChoices("payee", "provider"),
    )
    amount: float
    expires_at: int | str = Field(
        default=0,
        validation_alias=AliasChoices("expires_at", "expiry"),
    )
    status: DepositStatus
    tx_hash: str | None = None
    chain: str = ""
    created_at: int | str = 0
    updated_at: int | str = 0
