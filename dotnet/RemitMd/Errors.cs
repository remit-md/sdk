namespace RemitMd;

/// <summary>
/// Thrown by all remit.md SDK methods when the API returns an error or when
/// client-side validation fails.
/// </summary>
public sealed class RemitError : Exception
{
    /// <summary>Machine-readable error code (e.g. "INSUFFICIENT_FUNDS").</summary>
    public string Code { get; }

    /// <summary>
    /// Additional structured context about the error (e.g. required amount,
    /// available balance, rejected address). Null when no context is present.
    /// </summary>
    public IReadOnlyDictionary<string, object>? Context { get; }

    /// <summary>HTTP status code from the API response, or null for client-side errors.</summary>
    public int? HttpStatus { get; }

    internal RemitError(string code, string message,
        IReadOnlyDictionary<string, object>? context = null,
        int? httpStatus = null)
        : base(message)
    {
        Code = code;
        Context = context;
        HttpStatus = httpStatus;
    }

    public override string ToString() =>
        $"RemitError [{Code}]: {Message}" +
        (Context is { Count: > 0 } ctx
            ? " | context: " + string.Join(", ", ctx.Select(kv => $"{kv.Key}={kv.Value}"))
            : string.Empty);
}

/// <summary>Well-known error codes returned by remit.md.</summary>
public static class ErrorCodes
{
    // ── Auth errors ──────────────────────────────────────────────────────────
    public const string InvalidSignature     = "INVALID_SIGNATURE";
    public const string NonceReused          = "NONCE_REUSED";
    public const string TimestampExpired     = "TIMESTAMP_EXPIRED";
    public const string Unauthorized         = "UNAUTHORIZED";

    // ── Balance / funds ──────────────────────────────────────────────────────
    public const string InsufficientBalance  = "INSUFFICIENT_BALANCE";
    public const string BelowMinimum         = "BELOW_MINIMUM";

    // ── Escrow errors ────────────────────────────────────────────────────────
    public const string EscrowNotFound       = "ESCROW_NOT_FOUND";
    public const string EscrowAlreadyFunded  = "ESCROW_ALREADY_FUNDED";
    public const string EscrowExpired        = "ESCROW_EXPIRED";

    // ── Invoice errors ───────────────────────────────────────────────────────
    public const string InvalidInvoice       = "INVALID_INVOICE";
    public const string DuplicateInvoice     = "DUPLICATE_INVOICE";
    public const string SelfPayment          = "SELF_PAYMENT";
    public const string InvalidPaymentType   = "INVALID_PAYMENT_TYPE";

    // ── Tab errors ───────────────────────────────────────────────────────────
    public const string TabDepleted          = "TAB_DEPLETED";
    public const string TabExpired           = "TAB_EXPIRED";
    public const string TabNotFound          = "TAB_NOT_FOUND";

    // ── Stream errors ────────────────────────────────────────────────────────
    public const string StreamNotFound       = "STREAM_NOT_FOUND";
    public const string RateExceedsCap       = "RATE_EXCEEDS_CAP";

    // ── Bounty errors ────────────────────────────────────────────────────────
    public const string BountyExpired        = "BOUNTY_EXPIRED";
    public const string BountyClaimed        = "BOUNTY_CLAIMED";
    public const string BountyMaxAttempts    = "BOUNTY_MAX_ATTEMPTS";
    public const string BountyNotFound       = "BOUNTY_NOT_FOUND";

    // ── Chain errors ─────────────────────────────────────────────────────────
    public const string ChainMismatch        = "CHAIN_MISMATCH";
    public const string ChainUnsupported     = "CHAIN_UNSUPPORTED";

    // ── Cancellation errors ──────────────────────────────────────────────────
    public const string CancelBlockedClaimStart = "CANCEL_BLOCKED_CLAIM_START";
    public const string CancelBlockedEvidence   = "CANCEL_BLOCKED_EVIDENCE";

    // ── Protocol errors ──────────────────────────────────────────────────────
    public const string VersionMismatch      = "VERSION_MISMATCH";
    public const string NetworkError         = "NETWORK_ERROR";

    // ── Rate limiting ────────────────────────────────────────────────────────
    public const string RateLimited          = "RATE_LIMITED";

    // ── General / client-side errors ─────────────────────────────────────────
    public const string ServerError          = "SERVER_ERROR";
    public const string InvalidChain         = "INVALID_CHAIN";
    public const string InvalidAddress       = "INVALID_ADDRESS";
    public const string InvalidAmount        = "INVALID_AMOUNT";
    public const string InvalidPrivateKey    = "INVALID_PRIVATE_KEY";

    // ── Backward-compatibility aliases ───────────────────────────────────────
    /// <summary>Alias for InsufficientBalance (legacy name).</summary>
    public const string InsufficientFunds    = InsufficientBalance;
    /// <summary>Alias for NonceReused (legacy name).</summary>
    public const string DuplicateNonce       = NonceReused;
    /// <summary>Alias for TabDepleted (legacy name).</summary>
    public const string TabLimitExceeded     = TabDepleted;
    /// <summary>Alias for EscrowAlreadyFunded (legacy name).</summary>
    public const string EscrowAlreadyClosed  = EscrowAlreadyFunded;
    /// <summary>Alias for BountyClaimed (legacy name).</summary>
    public const string BountyAlreadyClosed  = BountyClaimed;
    /// <summary>Alias for StreamNotFound (legacy name).</summary>
    public const string StreamNotActive      = "STREAM_NOT_ACTIVE";
}
