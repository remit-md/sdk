package md.remit;

/**
 * Error codes returned by the remit.md API.
 * These match the error taxonomy defined in shared/errors.ts.
 */
public final class ErrorCodes {
    private ErrorCodes() {}

    // Auth
    public static final String UNAUTHORIZED        = "UNAUTHORIZED";
    public static final String FORBIDDEN           = "FORBIDDEN";
    public static final String INVALID_SIGNATURE   = "INVALID_SIGNATURE";
    public static final String NONCE_REUSED        = "NONCE_REUSED";
    public static final String TIMESTAMP_EXPIRED   = "TIMESTAMP_EXPIRED";

    // Validation
    public static final String INVALID_ADDRESS     = "INVALID_ADDRESS";
    public static final String INVALID_AMOUNT      = "INVALID_AMOUNT";
    public static final String INVALID_CHAIN       = "INVALID_CHAIN";
    public static final String INVALID_PARAM       = "INVALID_PARAM";

    // Domain - balance / funds
    public static final String INSUFFICIENT_BALANCE = "INSUFFICIENT_BALANCE";
    public static final String BELOW_MINIMUM        = "BELOW_MINIMUM";
    /** @deprecated Use {@link #INSUFFICIENT_BALANCE} instead. */
    @Deprecated
    public static final String INSUFFICIENT_FUNDS   = INSUFFICIENT_BALANCE;

    // Domain - escrow
    public static final String ESCROW_NOT_FOUND     = "ESCROW_NOT_FOUND";
    public static final String ESCROW_WRONG_STATE   = "ESCROW_WRONG_STATE";
    public static final String ESCROW_ALREADY_FUNDED = "ESCROW_ALREADY_FUNDED";
    public static final String ESCROW_EXPIRED       = "ESCROW_EXPIRED";

    // Domain - invoice
    public static final String INVALID_INVOICE      = "INVALID_INVOICE";
    public static final String DUPLICATE_INVOICE    = "DUPLICATE_INVOICE";
    public static final String SELF_PAYMENT         = "SELF_PAYMENT";
    public static final String INVALID_PAYMENT_TYPE = "INVALID_PAYMENT_TYPE";

    // Domain - tab
    public static final String TAB_NOT_FOUND        = "TAB_NOT_FOUND";
    public static final String TAB_LIMIT_EXCEEDED   = "TAB_LIMIT_EXCEEDED";
    public static final String TAB_DEPLETED         = "TAB_DEPLETED";
    public static final String TAB_EXPIRED          = "TAB_EXPIRED";

    // Domain - stream
    public static final String STREAM_NOT_FOUND     = "STREAM_NOT_FOUND";
    public static final String RATE_EXCEEDS_CAP     = "RATE_EXCEEDS_CAP";

    // Domain - bounty
    public static final String BOUNTY_NOT_FOUND     = "BOUNTY_NOT_FOUND";
    public static final String BOUNTY_EXPIRED       = "BOUNTY_EXPIRED";
    public static final String BOUNTY_CLAIMED       = "BOUNTY_CLAIMED";
    public static final String BOUNTY_MAX_ATTEMPTS  = "BOUNTY_MAX_ATTEMPTS";

    // Domain - deposit
    public static final String DEPOSIT_NOT_FOUND    = "DEPOSIT_NOT_FOUND";

    // Domain - chain
    public static final String CHAIN_MISMATCH       = "CHAIN_MISMATCH";
    public static final String CHAIN_UNSUPPORTED    = "CHAIN_UNSUPPORTED";

    // Domain - cancellation
    public static final String CANCEL_BLOCKED_CLAIM_START = "CANCEL_BLOCKED_CLAIM_START";
    public static final String CANCEL_BLOCKED_EVIDENCE    = "CANCEL_BLOCKED_EVIDENCE";

    // Infrastructure
    public static final String RATE_LIMITED         = "RATE_LIMITED";
    public static final String SERVER_ERROR         = "SERVER_ERROR";
    public static final String CHAIN_ERROR          = "CHAIN_ERROR";
    public static final String TIMEOUT              = "TIMEOUT";
    public static final String NOT_FOUND            = "NOT_FOUND";
    public static final String NETWORK_ERROR        = "NETWORK_ERROR";
    public static final String VERSION_MISMATCH     = "VERSION_MISMATCH";
}
