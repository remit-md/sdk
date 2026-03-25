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
/// 3. Builds and signs an EIP-3009 `transferWithAuthorization`
/// 4. Base64-encodes the `PAYMENT-SIGNATURE` header
/// 5. Retries the original request with payment attached
public final class X402Client: @unchecked Sendable {
    private let signer: any Signer
    private let address: String
    private let maxAutoPayUsdc: Double
    private let session: URLSession

    /// The last PAYMENT-REQUIRED decoded before payment. Useful for logging/display.
    public var lastPayment: PaymentRequired?

    public init(signer: any Signer, address: String, maxAutoPayUsdc: Double = 0.10) {
        self.signer = signer
        self.address = address
        self.maxAutoPayUsdc = maxAutoPayUsdc
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

        // 4. Parse chainId from CAIP-2 network string (e.g. "eip155:84532" -> 84532).
        let chainComponents = required.network.split(separator: ":")
        guard chainComponents.count == 2, let chainId = UInt64(chainComponents[1]) else {
            throw RemitError(RemitError.serverError, "Cannot parse chainId from network: \(required.network)")
        }

        // 5. Build EIP-3009 authorization fields.
        let nowSecs = UInt64(Date().timeIntervalSince1970)
        let validBefore = nowSecs + UInt64(required.maxTimeoutSeconds ?? 60)

        var nonceBytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { nonceBytes[i] = UInt8.random(in: 0...255) }
        let nonceData = Data(nonceBytes)
        let nonceHex = "0x" + nonceData.hexString

        // 6. Build EIP-712 digest for TransferWithAuthorization
        let digest = eip3009Hash(
            chainId: chainId,
            asset: required.asset,
            from: address,
            to: required.payTo,
            value: amountBaseUnits,
            validAfter: 0,
            validBefore: validBefore,
            nonce: nonceData
        )

        let signature = try signer.sign(digest: digest)

        // 7. Build PAYMENT-SIGNATURE JSON payload.
        let paymentPayload: [String: Any] = [
            "scheme": required.scheme,
            "network": required.network,
            "x402Version": 1,
            "payload": [
                "signature": signature,
                "authorization": [
                    "from": address,
                    "to": required.payTo,
                    "value": required.amount,
                    "validAfter": "0",
                    "validBefore": String(validBefore),
                    "nonce": nonceHex,
                ] as [String: Any],
            ] as [String: Any],
        ]

        let paymentJSON = try JSONSerialization.data(withJSONObject: paymentPayload)
        let paymentHeader = paymentJSON.base64EncodedString()

        // 8. Retry with PAYMENT-SIGNATURE header.
        var retryReq = originalRequest
        retryReq.setValue(paymentHeader, forHTTPHeaderField: "PAYMENT-SIGNATURE")

        let (data, response2) = try await session.data(for: retryReq)
        guard let http2 = response2 as? HTTPURLResponse else {
            throw RemitError(RemitError.networkError, "Non-HTTP response on retry")
        }

        return X402Response(data: data, response: http2)
    }
}

// MARK: - EIP-3009 hash computation

/// Compute the EIP-712 hash for a TransferWithAuthorization (EIP-3009).
///
/// Domain: name="USD Coin", version="2", chainId, verifyingContract=asset
/// Struct: TransferWithAuthorization(address from, address to, uint256 value,
///         uint256 validAfter, uint256 validBefore, bytes32 nonce)
private func eip3009Hash(
    chainId: UInt64,
    asset: String,
    from: String,
    to: String,
    value: UInt64,
    validAfter: UInt64,
    validBefore: UInt64,
    nonce: Data
) -> Data {
    let domainTypeHash = keccak256(Data("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".utf8))
    let typeHash = keccak256(Data("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)".utf8))

    let nameHash = keccak256(Data("USD Coin".utf8))
    let versionHash = keccak256(Data("2".utf8))
    let chainIdEnc = x402EncodeUint256(chainId)
    let assetEnc = x402EncodeAddress(asset)

    var domainData = Data()
    domainData.append(domainTypeHash)
    domainData.append(nameHash)
    domainData.append(versionHash)
    domainData.append(chainIdEnc)
    domainData.append(assetEnc)
    let domainSep = keccak256(domainData)

    let fromEnc = x402EncodeAddress(from)
    let toEnc = x402EncodeAddress(to)
    let valueEnc = x402EncodeUint256(value)
    let validAfterEnc = x402EncodeUint256(validAfter)
    let validBeforeEnc = x402EncodeUint256(validBefore)
    var paddedNonce = Data(repeating: 0, count: 32)
    let bytesToCopy = min(nonce.count, 32)
    paddedNonce.replaceSubrange(0..<bytesToCopy, with: nonce.prefix(bytesToCopy))

    var structData = Data()
    structData.append(typeHash)
    structData.append(fromEnc)
    structData.append(toEnc)
    structData.append(valueEnc)
    structData.append(validAfterEnc)
    structData.append(validBeforeEnc)
    structData.append(paddedNonce)
    let structHash = keccak256(structData)

    var finalData = Data([0x19, 0x01])
    finalData.append(domainSep)
    finalData.append(structHash)
    return keccak256(finalData)
}

private func x402EncodeUint256(_ value: UInt64) -> Data {
    var result = Data(repeating: 0, count: 32)
    var v = value
    for i in stride(from: 31, through: 24, by: -1) {
        result[i] = UInt8(v & 0xFF)
        v >>= 8
    }
    return result
}

private func x402EncodeAddress(_ address: String) -> Data {
    var result = Data(repeating: 0, count: 32)
    let hex = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
    guard hex.count == 40, let addrData = Data(hexString: hex) else { return result }
    result.replaceSubrange(12..<32, with: addrData)
    return result
}
