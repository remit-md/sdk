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
    // ── Payment errors ───────────────────────────────────────────────────────
    public const string InsufficientFunds    = "INSUFFICIENT_FUNDS";
    public const string InvalidRecipient     = "INVALID_RECIPIENT";
    public const string InvalidAmount        = "INVALID_AMOUNT";
    public const string PaymentFailed        = "PAYMENT_FAILED";
    public const string DuplicateNonce       = "DUPLICATE_NONCE";

    // ── Escrow errors ────────────────────────────────────────────────────────
    public const string EscrowNotFound       = "ESCROW_NOT_FOUND";
    public const string EscrowNotFunded      = "ESCROW_NOT_FUNDED";
    public const string EscrowAlreadyClosed  = "ESCROW_ALREADY_CLOSED";
    public const string EscrowExpired        = "ESCROW_EXPIRED";
    public const string Unauthorized         = "UNAUTHORIZED";

    // ── Tab errors ───────────────────────────────────────────────────────────
    public const string TabNotFound          = "TAB_NOT_FOUND";
    public const string TabLimitExceeded     = "TAB_LIMIT_EXCEEDED";
    public const string TabAlreadyClosed     = "TAB_ALREADY_CLOSED";
    public const string InvalidSignature     = "INVALID_SIGNATURE";

    // ── Stream errors ────────────────────────────────────────────────────────
    public const string StreamNotFound       = "STREAM_NOT_FOUND";
    public const string StreamNotActive      = "STREAM_NOT_ACTIVE";
    public const string NothingToWithdraw    = "NOTHING_TO_WITHDRAW";

    // ── Bounty errors ────────────────────────────────────────────────────────
    public const string BountyNotFound       = "BOUNTY_NOT_FOUND";
    public const string BountyAlreadyClosed  = "BOUNTY_ALREADY_CLOSED";

    // ── General errors ───────────────────────────────────────────────────────
    public const string InvalidChain         = "INVALID_CHAIN";
    public const string InvalidAddress       = "INVALID_ADDRESS";
    public const string RateLimited          = "RATE_LIMITED";
    public const string ServerError          = "SERVER_ERROR";
    public const string NetworkError         = "NETWORK_ERROR";
    public const string InvalidPrivateKey    = "INVALID_PRIVATE_KEY";
}
