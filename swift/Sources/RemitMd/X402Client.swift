import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - X402 Client

/// Raised when an x402 payment amount exceeds the configured auto-pay limit.
public struct AllowanceExceededError: Error, CustomStringConvertible {
    public let amountUsdc: Double
    public let limitUsdc: Double

    public var description: String {
        String(format: "x402 payment %.6f USDC exceeds auto-pay limit %.6f USDC", amountUsdc, limitUsdc)
    }
}

/// Shape of the base64-decoded PAYMENT-REQUIRED header.
public struct PaymentRequired: Codable, Sendable {
    public let scheme: String
    public let network: String
    public let amount: String
    public let asset: String
    public let payTo: String
    public let maxTimeoutSeconds: Int?
    /// V2 optional fields.
    public let resource: String?
    public let description: String?
    public let mimeType: String?
}

/// Response wrapper for x402 fetch results.
public struct X402Response: Sendable {
    public let data: Data
    public let response: HTTPURLResponse
}

/// `fetch` wrapper that auto-handles HTTP 402 Payment Required responses.
///
/// On receiving a 402, the client:
/// 1. Decodes the `PAYMENT-REQUIRED` header (base64 JSON)
/// 2. Checks the amount is within `maxAutoPayUsdc`
/// 3. Calls `/x402/prepare` to get hash + authorization fields
/// 4. Signs the hash
/// 5. Base64-encodes the `PAYMENT-SIGNATURE` header
/// 6. Retries the original request with payment attached
public final class X402Client: @unchecked Sendable {
    private let signer: any Signer
    private let address: String
    private let maxAutoPayUsdc: Double
    private let apiTransport: any Transport
    private let session: URLSession

    /// The last PAYMENT-REQUIRED decoded before payment. Useful for logging/display.
    public var lastPayment: PaymentRequired?

    public init(signer: any Signer, address: String, maxAutoPayUsdc: Double = 0.10, apiTransport: any Transport) {
        self.signer = signer
        self.address = address
        self.maxAutoPayUsdc = maxAutoPayUsdc
        self.apiTransport = apiTransport
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Make a fetch request, auto-paying any 402 responses within the configured limit.
    public func fetch(url: String, method: String = "GET", headers: [String: String]? = nil, body: Data? = nil) async throws -> X402Response {
        guard let requestURL = URL(string: url) else {
            throw RemitError(RemitError.serverError, "Invalid URL: \(url)")
        }

        var req = URLRequest(url: requestURL)
        req.httpMethod = method
        req.httpBody = body
        headers?.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw RemitError(RemitError.networkError, "Non-HTTP response")
        }

        if http.statusCode == 402 {
            return try await handle402(url: url, response: http, originalRequest: req)
        }

        return X402Response(data: data, response: http)
    }

    private func handle402(url: String, response: HTTPURLResponse, originalRequest: URLRequest) async throws -> X402Response {
        // 1. Decode PAYMENT-REQUIRED header
        guard let raw = response.value(forHTTPHeaderField: "PAYMENT-REQUIRED")
                ?? response.value(forHTTPHeaderField: "payment-required") else {
            throw RemitError(RemitError.serverError, "402 response missing PAYMENT-REQUIRED header")
        }

        guard let headerData = Data(base64Encoded: raw) else {
            throw RemitError(RemitError.serverError, "Cannot base64 decode PAYMENT-REQUIRED header")
        }

        let required = try JSONDecoder().decode(PaymentRequired.self, from: headerData)

        // 2. Only the "exact" scheme is supported.
        guard required.scheme == "exact" else {
            throw RemitError(RemitError.serverError, "Unsupported x402 scheme: \(required.scheme)")
        }

        // Store for caller inspection.
        self.lastPayment = required

        // 3. Check auto-pay limit.
        guard let amountBaseUnits = UInt64(required.amount) else {
            throw RemitError(RemitError.serverError, "Cannot parse amount: \(required.amount)")
        }
        let amountUsdc = Double(amountBaseUnits) / 1_000_000.0
        if amountUsdc > maxAutoPayUsdc {
            throw AllowanceExceededError(amountUsdc: amountUsdc, limitUsdc: maxAutoPayUsdc)
        }

        // 4. Call /x402/prepare to get the hash + authorization fields.
        let prepareData: X402PrepareResponse = try await apiTransport.request(
            method: "POST", path: "/api/v1/x402/prepare",
            body: X402PrepareBody(payment_required: raw, payer: address)
        )

        // 5. Sign the hash.
        let hashHex = prepareData.hash.hasPrefix("0x") ? String(prepareData.hash.dropFirst(2)) : prepareData.hash
        guard let hashBytes = Data(hexString: hashHex), hashBytes.count == 32 else {
            throw RemitError(RemitError.serverError, "Invalid hash from /x402/prepare: \(prepareData.hash)")
        }
        let signature = try await signer.signHash(hashBytes)

        // 6. Build PAYMENT-SIGNATURE JSON payload.
        let paymentPayload: [String: Any] = [
            "scheme": required.scheme,
            "network": required.network,
            "x402Version": 1,
            "payload": [
                "signature": signature,
                "authorization": [
                    "from": prepareData.from,
                    "to": prepareData.to,
                    "value": prepareData.value,
                    "validAfter": prepareData.validAfter,
                    "validBefore": prepareData.validBefore,
                    "nonce": prepareData.nonce,
                ] as [String: Any],
            ] as [String: Any],
        ]

        let paymentJSON = try JSONSerialization.data(withJSONObject: paymentPayload)
        let paymentHeader = paymentJSON.base64EncodedString()

        // 7. Retry with PAYMENT-SIGNATURE header.
        var retryReq = originalRequest
        retryReq.setValue(paymentHeader, forHTTPHeaderField: "PAYMENT-SIGNATURE")

        let (data, response2) = try await session.data(for: retryReq)
        guard let http2 = response2 as? HTTPURLResponse else {
            throw RemitError(RemitError.networkError, "Non-HTTP response on retry")
        }

        return X402Response(data: data, response: http2)
    }
}

// MARK: - /x402/prepare request/response

private struct X402PrepareBody: Codable {
    let payment_required: String
    let payer: String
}

private struct X402PrepareResponse: Codable {
    let hash: String
    let from: String
    let to: String
    let value: String
    let validAfter: String
    let validBefore: String
    let nonce: String

    enum CodingKeys: String, CodingKey {
        case hash, from, to, value, nonce
        case validAfter = "valid_after"
        case validBefore = "valid_before"
    }
}
