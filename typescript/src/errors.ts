/**
 * Typed error classes for remit.md error codes.
 *
 * Every API error code maps to a specific class so callers can handle precisely:
 *
 *   try {
 *     await wallet.pay(invoice);
 *   } catch (e) {
 *     if (e instanceof InsufficientBalanceError) {
 *       await wallet.requestTestnetFunds();
 *     }
 *   }
 */

export class RemitError extends Error {
  readonly code: string;
  readonly httpStatus: number;

  constructor(message: string, code = "UNKNOWN_ERROR", httpStatus = 500) {
    super(message);
    this.name = this.constructor.name;
    this.code = code;
    this.httpStatus = httpStatus;
  }
}

// ─── Auth errors ─────────────────────────────────────────────────────────────

export class InvalidSignatureError extends RemitError {
  constructor(msg = "Invalid EIP-712 signature.") {
    super(msg, "INVALID_SIGNATURE", 401);
  }
}

export class NonceReusedError extends RemitError {
  constructor(msg = "Nonce has already been used.") {
    super(msg, "NONCE_REUSED", 401);
  }
}

export class TimestampExpiredError extends RemitError {
  constructor(msg = "Request timestamp has expired.") {
    super(msg, "TIMESTAMP_EXPIRED", 401);
  }
}

export class UnauthorizedError extends RemitError {
  constructor(msg = "Authentication required.") {
    super(msg, "UNAUTHORIZED", 401);
  }
}

// ─── Balance / funds ──────────────────────────────────────────────────────────

export class InsufficientBalanceError extends RemitError {
  constructor(msg = "Wallet does not have enough USDC for this transaction + fee.") {
    super(msg, "INSUFFICIENT_BALANCE", 402);
  }
}

export class BelowMinimumError extends RemitError {
  constructor(msg = "Transaction amount is below $0.01 minimum.") {
    super(msg, "BELOW_MINIMUM", 400);
  }
}

// ─── Escrow errors ────────────────────────────────────────────────────────────

export class EscrowNotFoundError extends RemitError {
  constructor(msg = "Escrow not found.") {
    super(msg, "ESCROW_NOT_FOUND", 404);
  }
}

export class EscrowAlreadyFundedError extends RemitError {
  constructor(msg = "This invoice already has a funded escrow.") {
    super(msg, "ESCROW_ALREADY_FUNDED", 409);
  }
}

export class EscrowExpiredError extends RemitError {
  constructor(msg = "Escrow has expired.") {
    super(msg, "ESCROW_EXPIRED", 410);
  }
}

export class EscrowFrozenError extends RemitError {
  constructor(msg = "Escrow is frozen during dispute.") {
    super(msg, "ESCROW_FROZEN", 409);
  }
}

// ─── Invoice errors ───────────────────────────────────────────────────────────

export class InvalidInvoiceError extends RemitError {
  constructor(msg = "Invoice is malformed or invalid.") {
    super(msg, "INVALID_INVOICE", 400);
  }
}

export class DuplicateInvoiceError extends RemitError {
  constructor(msg = "An invoice with this ID already exists.") {
    super(msg, "DUPLICATE_INVOICE", 409);
  }
}

export class SelfPaymentError extends RemitError {
  constructor(msg = "Cannot pay yourself.") {
    super(msg, "SELF_PAYMENT", 400);
  }
}

export class InvalidPaymentTypeError extends RemitError {
  constructor(msg = "Payment type is not valid for this invoice.") {
    super(msg, "INVALID_PAYMENT_TYPE", 400);
  }
}

// ─── Tab errors ───────────────────────────────────────────────────────────────

export class TabDepletedError extends RemitError {
  constructor(msg = "Tab has reached its spending limit.") {
    super(msg, "TAB_DEPLETED", 402);
  }
}

export class TabExpiredError extends RemitError {
  constructor(msg = "Tab has expired.") {
    super(msg, "TAB_EXPIRED", 410);
  }
}

export class TabNotFoundError extends RemitError {
  constructor(msg = "Tab not found.") {
    super(msg, "TAB_NOT_FOUND", 404);
  }
}

// ─── Stream errors ────────────────────────────────────────────────────────────

export class StreamNotFoundError extends RemitError {
  constructor(msg = "Stream not found.") {
    super(msg, "STREAM_NOT_FOUND", 404);
  }
}

export class RateExceedsCapError extends RemitError {
  constructor(msg = "Streaming rate exceeds the maximum allowed.") {
    super(msg, "RATE_EXCEEDS_CAP", 422);
  }
}

// ─── Bounty errors ────────────────────────────────────────────────────────────

export class BountyExpiredError extends RemitError {
  constructor(msg = "Bounty has expired.") {
    super(msg, "BOUNTY_EXPIRED", 410);
  }
}

export class BountyClaimedError extends RemitError {
  constructor(msg = "Bounty has already been awarded.") {
    super(msg, "BOUNTY_CLAIMED", 409);
  }
}

export class BountyMaxAttemptsError extends RemitError {
  constructor(msg = "Bounty has reached maximum submission attempts.") {
    super(msg, "BOUNTY_MAX_ATTEMPTS", 422);
  }
}

export class BountyNotFoundError extends RemitError {
  constructor(msg = "Bounty not found.") {
    super(msg, "BOUNTY_NOT_FOUND", 404);
  }
}

// ─── Chain errors ─────────────────────────────────────────────────────────────

export class ChainMismatchError extends RemitError {
  constructor(msg = "Invoice chain does not match wallet chain.") {
    super(msg, "CHAIN_MISMATCH", 409);
  }
}

export class ChainUnsupportedError extends RemitError {
  constructor(msg = "This chain is not supported.") {
    super(msg, "CHAIN_UNSUPPORTED", 422);
  }
}

// ─── Rate limiting ────────────────────────────────────────────────────────────

export class RateLimitedError extends RemitError {
  constructor(msg = "Rate limit exceeded. Try again later.") {
    super(msg, "RATE_LIMITED", 429);
  }
}

// ─── Cancellation errors ──────────────────────────────────────────────────────

export class CancelBlockedClaimStartError extends RemitError {
  constructor(msg = "Cannot cancel after claim start.") {
    super(msg, "CANCEL_BLOCKED_CLAIM_START", 409);
  }
}

export class CancelBlockedEvidenceError extends RemitError {
  constructor(msg = "Cannot cancel while evidence is pending review.") {
    super(msg, "CANCEL_BLOCKED_EVIDENCE", 409);
  }
}

// ─── Protocol errors ──────────────────────────────────────────────────────────

export class VersionMismatchError extends RemitError {
  constructor(msg = "SDK version is not compatible with this API version.") {
    super(msg, "VERSION_MISMATCH", 422);
  }
}

export class NetworkError extends RemitError {
  constructor(msg = "Network request failed.") {
    super(msg, "NETWORK_ERROR", 503);
  }
}

// ─── Factory ──────────────────────────────────────────────────────────────────

const ERROR_MAP: Record<string, new (msg?: string) => RemitError> = {
  INVALID_SIGNATURE: InvalidSignatureError,
  NONCE_REUSED: NonceReusedError,
  TIMESTAMP_EXPIRED: TimestampExpiredError,
  UNAUTHORIZED: UnauthorizedError,
  INSUFFICIENT_BALANCE: InsufficientBalanceError,
  BELOW_MINIMUM: BelowMinimumError,
  ESCROW_NOT_FOUND: EscrowNotFoundError,
  ESCROW_ALREADY_FUNDED: EscrowAlreadyFundedError,
  ESCROW_EXPIRED: EscrowExpiredError,
  ESCROW_FROZEN: EscrowFrozenError,
  INVALID_INVOICE: InvalidInvoiceError,
  DUPLICATE_INVOICE: DuplicateInvoiceError,
  SELF_PAYMENT: SelfPaymentError,
  INVALID_PAYMENT_TYPE: InvalidPaymentTypeError,
  TAB_DEPLETED: TabDepletedError,
  TAB_EXPIRED: TabExpiredError,
  TAB_NOT_FOUND: TabNotFoundError,
  STREAM_NOT_FOUND: StreamNotFoundError,
  RATE_EXCEEDS_CAP: RateExceedsCapError,
  BOUNTY_EXPIRED: BountyExpiredError,
  BOUNTY_CLAIMED: BountyClaimedError,
  BOUNTY_MAX_ATTEMPTS: BountyMaxAttemptsError,
  BOUNTY_NOT_FOUND: BountyNotFoundError,
  CHAIN_MISMATCH: ChainMismatchError,
  CHAIN_UNSUPPORTED: ChainUnsupportedError,
  RATE_LIMITED: RateLimitedError,
  CANCEL_BLOCKED_CLAIM_START: CancelBlockedClaimStartError,
  CANCEL_BLOCKED_EVIDENCE: CancelBlockedEvidenceError,
  VERSION_MISMATCH: VersionMismatchError,
};

/** Map an API error code + message into the appropriate typed error. */
export function fromErrorCode(code: string, message?: string): RemitError {
  const Cls = ERROR_MAP[code];
  if (Cls) return new Cls(message);
  return new RemitError(message ?? `Unknown error: ${code}`, code);
}
