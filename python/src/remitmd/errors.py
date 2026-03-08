"""Typed exceptions for remit.md error codes.

Every API error code maps to a specific exception class so callers can
handle errors precisely:

    try:
        await wallet.pay(invoice)
    except InsufficientBalance:
        await wallet.request_testnet_funds()
"""

from __future__ import annotations


class RemitError(Exception):
    """Base class for all remit.md errors."""

    code: str = "UNKNOWN_ERROR"
    http_status: int = 500

    def __init__(self, message: str, code: str | None = None, http_status: int | None = None):
        super().__init__(message)
        if code is not None:
            self.code = code
        if http_status is not None:
            self.http_status = http_status


# ─── Auth errors ─────────────────────────────────────────────────────────────

class InvalidSignature(RemitError):
    code = "INVALID_SIGNATURE"
    http_status = 401


class SignatureExpired(RemitError):
    code = "SIGNATURE_EXPIRED"
    http_status = 401


class NonceReused(RemitError):
    code = "NONCE_REUSED"
    http_status = 401


class Unauthorized(RemitError):
    code = "UNAUTHORIZED"
    http_status = 401


# ─── Balance / funds ──────────────────────────────────────────────────────────

class InsufficientBalance(RemitError):
    code = "INSUFFICIENT_BALANCE"
    http_status = 402


class InsufficientAllowance(RemitError):
    code = "INSUFFICIENT_ALLOWANCE"
    http_status = 402


# ─── Not found ────────────────────────────────────────────────────────────────

class InvoiceNotFound(RemitError):
    code = "INVOICE_NOT_FOUND"
    http_status = 404


class EscrowNotFound(RemitError):
    code = "ESCROW_NOT_FOUND"
    http_status = 404


class TabNotFound(RemitError):
    code = "TAB_NOT_FOUND"
    http_status = 404


class StreamNotFound(RemitError):
    code = "STREAM_NOT_FOUND"
    http_status = 404


class BountyNotFound(RemitError):
    code = "BOUNTY_NOT_FOUND"
    http_status = 404


class DepositNotFound(RemitError):
    code = "DEPOSIT_NOT_FOUND"
    http_status = 404


class WebhookNotFound(RemitError):
    code = "WEBHOOK_NOT_FOUND"
    http_status = 404


# ─── State machine / validation ───────────────────────────────────────────────

class InvalidState(RemitError):
    code = "INVALID_STATE"
    http_status = 409


class TabLimitExceeded(RemitError):
    code = "TAB_LIMIT_EXCEEDED"
    http_status = 402


class TabExpired(RemitError):
    code = "TAB_EXPIRED"
    http_status = 409


class EscrowTimeout(RemitError):
    code = "ESCROW_TIMEOUT"
    http_status = 409


class MilestoneNotFound(RemitError):
    code = "MILESTONE_NOT_FOUND"
    http_status = 404


class InvalidAmount(RemitError):
    code = "INVALID_AMOUNT"
    http_status = 422


class InvalidAddress(RemitError):
    code = "INVALID_ADDRESS"
    http_status = 422


class InvalidChain(RemitError):
    code = "INVALID_CHAIN"
    http_status = 422


# ─── Rate limiting ────────────────────────────────────────────────────────────

class RateLimitExceeded(RemitError):
    code = "RATE_LIMIT_EXCEEDED"
    http_status = 429


# ─── Server errors ────────────────────────────────────────────────────────────

class ChainUnavailable(RemitError):
    code = "CHAIN_UNAVAILABLE"
    http_status = 503


class TransactionFailed(RemitError):
    code = "TRANSACTION_FAILED"
    http_status = 500


class ServerError(RemitError):
    code = "SERVER_ERROR"
    http_status = 500


# ─── Error code → exception class mapping ────────────────────────────────────

_CODE_MAP: dict[str, type[RemitError]] = {
    "INVALID_SIGNATURE": InvalidSignature,
    "SIGNATURE_EXPIRED": SignatureExpired,
    "NONCE_REUSED": NonceReused,
    "UNAUTHORIZED": Unauthorized,
    "INSUFFICIENT_BALANCE": InsufficientBalance,
    "INSUFFICIENT_ALLOWANCE": InsufficientAllowance,
    "INVOICE_NOT_FOUND": InvoiceNotFound,
    "ESCROW_NOT_FOUND": EscrowNotFound,
    "TAB_NOT_FOUND": TabNotFound,
    "STREAM_NOT_FOUND": StreamNotFound,
    "BOUNTY_NOT_FOUND": BountyNotFound,
    "DEPOSIT_NOT_FOUND": DepositNotFound,
    "WEBHOOK_NOT_FOUND": WebhookNotFound,
    "INVALID_STATE": InvalidState,
    "TAB_LIMIT_EXCEEDED": TabLimitExceeded,
    "TAB_EXPIRED": TabExpired,
    "ESCROW_TIMEOUT": EscrowTimeout,
    "MILESTONE_NOT_FOUND": MilestoneNotFound,
    "INVALID_AMOUNT": InvalidAmount,
    "INVALID_ADDRESS": InvalidAddress,
    "INVALID_CHAIN": InvalidChain,
    "RATE_LIMIT_EXCEEDED": RateLimitExceeded,
    "CHAIN_UNAVAILABLE": ChainUnavailable,
    "TRANSACTION_FAILED": TransactionFailed,
    "SERVER_ERROR": ServerError,
}


def from_error_code(code: str, message: str, http_status: int) -> RemitError:
    """Construct the most specific exception for a given API error code."""
    cls = _CODE_MAP.get(code, RemitError)
    return cls(message, code=code, http_status=http_status)
