package md.remit;

/**
 * Error codes returned by the remit.md API.
 * These match the error taxonomy defined in shared/errors.ts.
 */
public final class ErrorCodes {
    private ErrorCodes() {}

    // Auth
    public static final String UNAUTHORIZED       = "UNAUTHORIZED";
    public static final String FORBIDDEN          = "FORBIDDEN";
    public static final String INVALID_SIGNATURE  = "INVALID_SIGNATURE";
    public static final String NONCE_REUSED       = "NONCE_REUSED";

    // Validation
    public static final String INVALID_ADDRESS    = "INVALID_ADDRESS";
    public static final String INVALID_AMOUNT     = "INVALID_AMOUNT";
    public static final String INVALID_CHAIN      = "INVALID_CHAIN";
    public static final String INVALID_PARAM      = "INVALID_PARAM";

    // Domain
    public static final String INSUFFICIENT_FUNDS = "INSUFFICIENT_FUNDS";
    public static final String ESCROW_NOT_FOUND   = "ESCROW_NOT_FOUND";
    public static final String ESCROW_WRONG_STATE = "ESCROW_WRONG_STATE";
    public static final String TAB_NOT_FOUND      = "TAB_NOT_FOUND";
    public static final String TAB_LIMIT_EXCEEDED = "TAB_LIMIT_EXCEEDED";
    public static final String STREAM_NOT_FOUND   = "STREAM_NOT_FOUND";
    public static final String BOUNTY_NOT_FOUND   = "BOUNTY_NOT_FOUND";
    public static final String DEPOSIT_NOT_FOUND  = "DEPOSIT_NOT_FOUND";

    // Infrastructure
    public static final String RATE_LIMITED       = "RATE_LIMITED";
    public static final String SERVER_ERROR       = "SERVER_ERROR";
    public static final String CHAIN_ERROR        = "CHAIN_ERROR";
    public static final String TIMEOUT            = "TIMEOUT";
    public static final String NOT_FOUND          = "NOT_FOUND";
}
