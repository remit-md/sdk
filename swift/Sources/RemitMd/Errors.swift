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
    // MARK: - Error code constants

    public static let invalidAddress        = "INVALID_ADDRESS"
    public static let invalidAmount         = "INVALID_AMOUNT"
    public static let insufficientFunds     = "INSUFFICIENT_FUNDS"
    public static let escrowNotFound        = "ESCROW_NOT_FOUND"
    public static let tabNotFound           = "TAB_NOT_FOUND"
    public static let streamNotFound        = "STREAM_NOT_FOUND"
    public static let bountyNotFound        = "BOUNTY_NOT_FOUND"
    public static let depositNotFound       = "DEPOSIT_NOT_FOUND"
    public static let unauthorized          = "UNAUTHORIZED"
    public static let rateLimited           = "RATE_LIMITED"
    public static let networkError          = "NETWORK_ERROR"
    public static let serverError           = "SERVER_ERROR"
    public static let nonceReused           = "NONCE_REUSED"
    public static let signatureInvalid      = "SIGNATURE_INVALID"
    public static let escrowAlreadyReleased = "ESCROW_ALREADY_RELEASED"
    public static let escrowExpired         = "ESCROW_EXPIRED"
    public static let tabLimitExceeded      = "TAB_LIMIT_EXCEEDED"
    public static let bountyAlreadyAwarded  = "BOUNTY_ALREADY_AWARDED"
    public static let streamNotActive       = "STREAM_NOT_ACTIVE"
    public static let depositAlreadySettled = "DEPOSIT_ALREADY_SETTLED"
    public static let usdcTransferFailed    = "USDC_TRANSFER_FAILED"
    public static let chainUnavailable      = "CHAIN_UNAVAILABLE"

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

    static func insufficientFunds(available: Double, required: Double) -> RemitError {
        RemitError(insufficientFunds,
            "wallet has \(available) USDC but \(required) USDC required",
            context: ["available": "\(available)", "required": "\(required)"])
    }

    static func notFound(_ code: String, _ id: String) -> RemitError {
        RemitError(code, "'\(id)' not found", context: ["id": id])
    }
}
