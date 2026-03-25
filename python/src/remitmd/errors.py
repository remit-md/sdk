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
    code = "TIMESTAMP_EXPIRED"
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


class BelowMinimum(RemitError):
    code = "BELOW_MINIMUM"
    http_status = 400


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


class EscrowAlreadyFunded(RemitError):
    code = "ESCROW_ALREADY_FUNDED"
    http_status = 409


class EscrowExpired(RemitError):
    code = "ESCROW_EXPIRED"
    http_status = 410


class InvalidInvoice(RemitError):
    code = "INVALID_INVOICE"
    http_status = 400


class DuplicateInvoice(RemitError):
    code = "DUPLICATE_INVOICE"
    http_status = 409


class SelfPayment(RemitError):
    code = "SELF_PAYMENT"
    http_status = 400


class InvalidPaymentType(RemitError):
    code = "INVALID_PAYMENT_TYPE"
    http_status = 400


class TabLimitExceeded(RemitError):
    code = "TAB_LIMIT_EXCEEDED"
    http_status = 402


class TabDepleted(RemitError):
    code = "TAB_DEPLETED"
    http_status = 402


class TabExpired(RemitError):
    code = "TAB_EXPIRED"
    http_status = 410


class EscrowTimeout(RemitError):
    code = "ESCROW_TIMEOUT"
    http_status = 409


class MilestoneNotFound(RemitError):
    code = "MILESTONE_NOT_FOUND"
    http_status = 404


class RateExceedsCap(RemitError):
    code = "RATE_EXCEEDS_CAP"
    http_status = 422


class BountyExpired(RemitError):
    code = "BOUNTY_EXPIRED"
    http_status = 410


class BountyClaimed(RemitError):
    code = "BOUNTY_CLAIMED"
    http_status = 409


class BountyMaxAttempts(RemitError):
    code = "BOUNTY_MAX_ATTEMPTS"
    http_status = 422


class InvalidAmount(RemitError):
    code = "INVALID_AMOUNT"
    http_status = 422


class InvalidAddress(RemitError):
    code = "INVALID_ADDRESS"
    http_status = 422


class InvalidChain(RemitError):
    code = "INVALID_CHAIN"
    http_status = 422


class ChainMismatch(RemitError):
    code = "CHAIN_MISMATCH"
    http_status = 409


class ChainUnsupported(RemitError):
    code = "CHAIN_UNSUPPORTED"
    http_status = 422


# ─── Rate limiting ────────────────────────────────────────────────────────────


class RateLimitExceeded(RemitError):
    code = "RATE_LIMITED"
    http_status = 429


# ─── Cancellation errors ─────────────────────────────────────────────────────


class CancelBlockedClaimStart(RemitError):
    code = "CANCEL_BLOCKED_CLAIM_START"
    http_status = 409


class CancelBlockedEvidence(RemitError):
    code = "CANCEL_BLOCKED_EVIDENCE"
    http_status = 409


# ─── Protocol errors ─────────────────────────────────────────────────────────


class VersionMismatch(RemitError):
    code = "VERSION_MISMATCH"
    http_status = 422


class NetworkError(RemitError):
    code = "NETWORK_ERROR"
    http_status = 503


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
    # Auth
    "INVALID_SIGNATURE": InvalidSignature,
    "TIMESTAMP_EXPIRED": SignatureExpired,
    "SIGNATURE_EXPIRED": SignatureExpired,  # backwards-compat alias
    "NONCE_REUSED": NonceReused,
    "UNAUTHORIZED": Unauthorized,
    # Balance / funds
    "INSUFFICIENT_BALANCE": InsufficientBalance,
    "INSUFFICIENT_ALLOWANCE": InsufficientAllowance,
    "BELOW_MINIMUM": BelowMinimum,
    # Not found
    "INVOICE_NOT_FOUND": InvoiceNotFound,
    "ESCROW_NOT_FOUND": EscrowNotFound,
    "TAB_NOT_FOUND": TabNotFound,
    "STREAM_NOT_FOUND": StreamNotFound,
    "BOUNTY_NOT_FOUND": BountyNotFound,
    "DEPOSIT_NOT_FOUND": DepositNotFound,
    "WEBHOOK_NOT_FOUND": WebhookNotFound,
    "MILESTONE_NOT_FOUND": MilestoneNotFound,
    # Escrow
    "ESCROW_ALREADY_FUNDED": EscrowAlreadyFunded,
    "ESCROW_EXPIRED": EscrowExpired,
    "ESCROW_TIMEOUT": EscrowTimeout,
    # Invoice
    "INVALID_INVOICE": InvalidInvoice,
    "DUPLICATE_INVOICE": DuplicateInvoice,
    "SELF_PAYMENT": SelfPayment,
    "INVALID_PAYMENT_TYPE": InvalidPaymentType,
    # State / validation
    "INVALID_STATE": InvalidState,
    "TAB_LIMIT_EXCEEDED": TabLimitExceeded,
    "TAB_DEPLETED": TabDepleted,
    "TAB_EXPIRED": TabExpired,
    "INVALID_AMOUNT": InvalidAmount,
    "INVALID_ADDRESS": InvalidAddress,
    "INVALID_CHAIN": InvalidChain,
    # Stream
    "RATE_EXCEEDS_CAP": RateExceedsCap,
    # Bounty
    "BOUNTY_EXPIRED": BountyExpired,
    "BOUNTY_CLAIMED": BountyClaimed,
    "BOUNTY_MAX_ATTEMPTS": BountyMaxAttempts,
    # Chain
    "CHAIN_MISMATCH": ChainMismatch,
    "CHAIN_UNSUPPORTED": ChainUnsupported,
    # Rate limiting
    "RATE_LIMITED": RateLimitExceeded,
    "RATE_LIMIT_EXCEEDED": RateLimitExceeded,  # backwards-compat alias
    # Cancellation
    "CANCEL_BLOCKED_CLAIM_START": CancelBlockedClaimStart,
    "CANCEL_BLOCKED_EVIDENCE": CancelBlockedEvidence,
    # Protocol
    "VERSION_MISMATCH": VersionMismatch,
    "NETWORK_ERROR": NetworkError,
    # Server
    "CHAIN_UNAVAILABLE": ChainUnavailable,
    "TRANSACTION_FAILED": TransactionFailed,
    "SERVER_ERROR": ServerError,
}


def from_error_code(code: str, message: str, http_status: int) -> RemitError:
    """Construct the most specific exception for a given API error code."""
    cls = _CODE_MAP.get(code, RemitError)
    return cls(message, code=code, http_status=http_status)
