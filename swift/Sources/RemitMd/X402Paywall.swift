import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - X402 Paywall

/// Result of payment verification.
public struct CheckResult: Codable, Sendable {
    public let isValid: Bool
    public let invalidReason: String?
}

/// x402 paywall for service providers.
///
/// Providers use this to:
/// - Return HTTP 402 responses with properly formatted `PAYMENT-REQUIRED` headers
/// - Verify incoming `PAYMENT-SIGNATURE` headers against the remit.md facilitator
///
/// ```swift
/// let paywall = X402Paywall(
///     walletAddress: "0xYourProviderWallet",
///     amountUsdc: 0.001,
///     network: "eip155:84532",
///     asset: "0x2d846325766921935f37d5b4478196d3ef93707c"
/// )
///
/// // Check a payment header
/// let result = try await paywall.check(paymentSig: headerValue)
/// if !result.isValid { /* return 402 */ }
/// ```
public struct X402Paywall: Sendable {
    private let walletAddress: String
    private let amountBaseUnits: String
    private let network: String
    private let asset: String
    private let facilitatorUrl: String
    private let facilitatorToken: String
    private let maxTimeoutSeconds: Int
    private let resource: String?
    private let paywallDescription: String?
    private let mimeType: String?
    private let session: URLSession

    public init(
        walletAddress: String,
        amountUsdc: Double,
        network: String,
        asset: String,
        facilitatorUrl: String = "https://remit.md",
        facilitatorToken: String = "",
        maxTimeoutSeconds: Int = 60,
        resource: String? = nil,
        description: String? = nil,
        mimeType: String? = nil
    ) {
        self.walletAddress = walletAddress
        self.amountBaseUnits = String(Int(round(amountUsdc * 1_000_000)))
        self.network = network
        self.asset = asset
        var url = facilitatorUrl
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        self.facilitatorUrl = url
        self.facilitatorToken = facilitatorToken
        self.maxTimeoutSeconds = maxTimeoutSeconds
        self.resource = resource
        self.paywallDescription = description
        self.mimeType = mimeType
        self.session = URLSession.shared
    }

    /// Return the base64-encoded JSON `PAYMENT-REQUIRED` header value.
    public func paymentRequiredHeader() -> String {
        var payload: [String: Any] = [
            "scheme": "exact",
            "network": network,
            "amount": amountBaseUnits,
            "asset": asset,
            "payTo": walletAddress,
            "maxTimeoutSeconds": maxTimeoutSeconds,
        ]
        if let resource { payload["resource"] = resource }
        if let paywallDescription { payload["description"] = paywallDescription }
        if let mimeType { payload["mimeType"] = mimeType }

        guard let json = try? JSONSerialization.data(withJSONObject: payload) else {
            return ""
        }
        return json.base64EncodedString()
    }

    /// Check whether a `PAYMENT-SIGNATURE` header represents a valid payment.
    ///
    /// Calls the remit.md facilitator's `/api/v1/x402/verify` endpoint.
    ///
    /// - Parameter paymentSig: The raw header value (base64 JSON), or nil if absent.
    /// - Returns: `CheckResult` with `isValid` and optional `invalidReason`.
    public func check(paymentSig: String?) async throws -> CheckResult {
        guard let paymentSig, !paymentSig.isEmpty else {
            return CheckResult(isValid: false, invalidReason: nil)
        }

        guard let paymentData = Data(base64Encoded: paymentSig),
              let paymentPayload = try? JSONSerialization.jsonObject(with: paymentData) else {
            return CheckResult(isValid: false, invalidReason: "INVALID_PAYLOAD")
        }

        let body: [String: Any] = [
            "paymentPayload": paymentPayload,
            "paymentRequired": [
                "scheme": "exact",
                "network": network,
                "amount": amountBaseUnits,
                "asset": asset,
                "payTo": walletAddress,
                "maxTimeoutSeconds": maxTimeoutSeconds,
            ] as [String: Any],
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return CheckResult(isValid: false, invalidReason: "FACILITATOR_ERROR")
        }

        guard let url = URL(string: "\(facilitatorUrl)/api/v1/x402/verify") else {
            return CheckResult(isValid: false, invalidReason: "FACILITATOR_ERROR")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        if !facilitatorToken.isEmpty {
            req.setValue("Bearer \(facilitatorToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return CheckResult(isValid: false, invalidReason: "FACILITATOR_ERROR")
            }
            let result = try JSONDecoder().decode(CheckResult.self, from: data)
            return result
        } catch {
            return CheckResult(isValid: false, invalidReason: "FACILITATOR_ERROR")
        }
    }
}
