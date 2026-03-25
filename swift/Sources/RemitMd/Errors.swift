/// Structured error raised by all remit.md SDK operations.
///
/// Every error has a machine-readable code, a human-readable message with
/// actionable context, and a docURL pointing to the specific error documentation.
///
/// ```swift
/// do {
///     try await wallet.pay(to: "bad-address", amount: 1.0)
/// } catch let e as RemitError {
///     print(e.code)    // "INVALID_ADDRESS"
///     print(e.message) // "[INVALID_ADDRESS] expected 0x-prefixed ..."
///     print(e.docURL)  // "https://remit.md/docs/api-reference/error-codes#invalid_address"
/// }
/// ```
public struct RemitError: Error, CustomStringConvertible {
    // MARK: - Error code constants (canonical — matches TS SDK)

    // Auth errors
    public static let invalidSignature      = "INVALID_SIGNATURE"
    public static let nonceReused           = "NONCE_REUSED"
    public static let timestampExpired      = "TIMESTAMP_EXPIRED"
    public static let unauthorized          = "UNAUTHORIZED"

    // Balance / funds
    public static let insufficientBalance   = "INSUFFICIENT_BALANCE"
    public static let belowMinimum          = "BELOW_MINIMUM"

    // Escrow errors
    public static let escrowNotFound        = "ESCROW_NOT_FOUND"
    public static let escrowAlreadyFunded   = "ESCROW_ALREADY_FUNDED"
    public static let escrowExpired         = "ESCROW_EXPIRED"

    // Invoice errors
    public static let invalidInvoice        = "INVALID_INVOICE"
    public static let duplicateInvoice      = "DUPLICATE_INVOICE"
    public static let selfPayment           = "SELF_PAYMENT"
    public static let invalidPaymentType    = "INVALID_PAYMENT_TYPE"

    // Tab errors
    public static let tabDepleted           = "TAB_DEPLETED"
    public static let tabExpired            = "TAB_EXPIRED"
    public static let tabNotFound           = "TAB_NOT_FOUND"

    // Stream errors
    public static let streamNotFound        = "STREAM_NOT_FOUND"
    public static let rateExceedsCap        = "RATE_EXCEEDS_CAP"

    // Bounty errors
    public static let bountyExpired         = "BOUNTY_EXPIRED"
    public static let bountyClaimed         = "BOUNTY_CLAIMED"
    public static let bountyMaxAttempts     = "BOUNTY_MAX_ATTEMPTS"
    public static let bountyNotFound        = "BOUNTY_NOT_FOUND"

    // Chain errors
    public static let chainMismatch         = "CHAIN_MISMATCH"
    public static let chainUnsupported      = "CHAIN_UNSUPPORTED"

    // Rate limiting
    public static let rateLimited           = "RATE_LIMITED"

    // Cancellation errors
    public static let cancelBlockedClaimStart = "CANCEL_BLOCKED_CLAIM_START"
    public static let cancelBlockedEvidence   = "CANCEL_BLOCKED_EVIDENCE"

    // Protocol errors
    public static let versionMismatch       = "VERSION_MISMATCH"
    public static let networkError          = "NETWORK_ERROR"

    // Legacy aliases (kept for backward compatibility within SDK internals)
    public static let invalidAddress        = "INVALID_ADDRESS"
    public static let invalidAmount         = "INVALID_AMOUNT"
    public static let serverError           = "SERVER_ERROR"
    public static let escrowAlreadyCompleted = "ESCROW_ALREADY_COMPLETED"
    public static let tabLimitExceeded      = "TAB_LIMIT_EXCEEDED"
    public static let bountyAlreadyAwarded  = "BOUNTY_ALREADY_AWARDED"
    public static let depositNotFound       = "DEPOSIT_NOT_FOUND"
    public static let streamNotActive       = "STREAM_NOT_ACTIVE"
    public static let depositAlreadyResolved = "DEPOSIT_ALREADY_RESOLVED"
    public static let usdcTransferFailed    = "USDC_TRANSFER_FAILED"
    public static let chainUnavailable      = "CHAIN_UNAVAILABLE"

    // Removed aliases — old names that mapped to wrong codes
    @available(*, deprecated, renamed: "invalidSignature")
    public static let signatureInvalid      = "INVALID_SIGNATURE"
    @available(*, deprecated, renamed: "insufficientBalance")
    public static let insufficientFunds     = "INSUFFICIENT_BALANCE"

    // MARK: - Properties

    public let code: String
    public let message: String
    public let docURL: String
    public let context: [String: String]

    // MARK: - Init

    public init(_ code: String, _ message: String, context: [String: String] = [:]) {
        self.code = code
        self.message = "[\(code)] \(message) — https://remit.md/docs/api-reference/error-codes#\(code.lowercased())"
        self.docURL = "https://remit.md/docs/api-reference/error-codes#\(code.lowercased())"
        self.context = context
    }

    public var description: String { message }

    // MARK: - Convenience factories

    static func invalidAddress(_ input: String) -> RemitError {
        RemitError(invalidAddress,
            "expected 0x-prefixed 40-character hex string, got '\(input)'",
            context: ["input": input])
    }

    static func invalidAmount(_ amount: Double, reason: String) -> RemitError {
        RemitError(invalidAmount,
            "\(reason); got \(amount)",
            context: ["amount": "\(amount)"])
    }

    static func insufficientBalance(available: Double, required: Double) -> RemitError {
        RemitError(insufficientBalance,
            "wallet has \(available) USDC but \(required) USDC required",
            context: ["available": "\(available)", "required": "\(required)"])
    }

    static func notFound(_ code: String, _ id: String) -> RemitError {
        RemitError(code, "'\(id)' not found", context: ["id": id])
    }
}
