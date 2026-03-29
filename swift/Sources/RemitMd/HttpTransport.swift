import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Transport protocol

/// HTTP transport layer. Inject ``MockTransport`` in tests, ``HttpTransport`` in production.
public protocol Transport: Sendable {
    func request<T: Decodable>(
        method: String,
        path: String,
        body: (any Encodable)?
    ) async throws -> T
}

// MARK: - Real HTTP transport

internal final class HttpTransport: Transport, @unchecked Sendable {
    private let baseURL: String
    private let chainId: UInt64
    private let routerAddress: String
    private let signer: any Signer
    private let session: URLSession
    private let maxRetries = 3

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: timestamp)
            }
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date from '\(string)'")
        }
        return d
    }()

    init(baseURL: String, chainId: UInt64, routerAddress: String, signer: any Signer) {
        self.baseURL = baseURL
        self.chainId = chainId
        self.routerAddress = routerAddress
        self.signer = signer
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func request<T: Decodable>(
        method: String,
        path: String,
        body: (any Encodable)?
    ) async throws -> T {
        let url = URL(string: baseURL + path)!
        let bodyData: Data? = if let body { try encodeBody(body) } else { nil }

        // Idempotency key generated ONCE before the retry loop so every attempt
        // sends the same key, enabling server-side deduplication.
        let idempotencyKey = UUID().uuidString.lowercased()

        // Sign the path without query string, matching server's OriginalUri.
        let pathOnly = path.split(separator: "?").first.map(String.init) ?? path

        return try await withRetry(maxRetries: maxRetries) {
            // Fresh timestamp, nonce, and signature for each retry attempt
            // so the server never rejects a stale timestamp or reused nonce.
            var nonceBytes = [UInt8](repeating: 0, count: 32)
            for i in 0..<32 { nonceBytes[i] = UInt8.random(in: 0...255) }
            let nonceData = Data(nonceBytes)
            let nonceHex = "0x" + nonceData.hexString

            let timestamp = UInt64(Date().timeIntervalSince1970)

            let digest = eip712Hash(
                chainId: self.chainId,
                routerAddress: self.routerAddress,
                method: method,
                path: pathOnly,
                timestamp: timestamp,
                nonce: nonceData
            )
            let sig = try self.signer.sign(digest: digest)

            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("remitmd-swift/0.1.0", forHTTPHeaderField: "User-Agent")
            req.httpBody = bodyData

            req.setValue(self.signer.address, forHTTPHeaderField: "X-Remit-Agent")
            req.setValue(nonceHex, forHTTPHeaderField: "X-Remit-Nonce")
            req.setValue(String(timestamp), forHTTPHeaderField: "X-Remit-Timestamp")
            req.setValue(sig, forHTTPHeaderField: "X-Remit-Signature")

            if method == "POST" || method == "PUT" || method == "PATCH" {
                req.setValue(idempotencyKey, forHTTPHeaderField: "X-Idempotency-Key")
            }

            let (data, response) = try await self.session.data(for: req)
            let http = response as! HTTPURLResponse

            if http.statusCode == 200 || http.statusCode == 201 {
                return try Self.decoder.decode(T.self, from: data)
            }
            if http.statusCode == 204 {
                // Empty response - try decoding an empty JSON object
                let emptyJSON = Data("{}".utf8)
                return try Self.decoder.decode(T.self, from: emptyJSON)
            }

            // Parse error body - check nested error.code first (TS parity)
            let errCode: String
            let errMessage: String
            if let parsed = try? JSONDecoder().decode(ApiErrorBody.self, from: data) {
                errCode = parsed.error?.code ?? parsed.code ?? "HTTP_\(http.statusCode)"
                errMessage = parsed.error?.message ?? parsed.message ?? "HTTP \(http.statusCode)"
            } else {
                errCode = "HTTP_\(http.statusCode)"
                errMessage = "HTTP \(http.statusCode)"
            }

            throw RemitError(errCode, errMessage)
        }
    }

    /// Retryable HTTP status codes - matches TS SDK's RETRYABLE set.
    private static let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504]
    /// Exponential-ish backoff delays in nanoseconds (200ms, 600ms, 1800ms).
    private static let delayNs: [UInt64] = [200_000_000, 600_000_000, 1_800_000_000]

    private func withRetry<T>(maxRetries: Int, fn: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                return try await fn()
            } catch let e as RemitError {
                // Only retry on retryable HTTP status codes.
                // Parse the HTTP status from the error code (e.g. "HTTP_502") or known codes.
                let isRetryable = e.code == RemitError.rateLimited
                    || e.code == RemitError.serverError
                    || e.code == RemitError.networkError
                    || e.code.hasPrefix("HTTP_") && Self.retryableStatuses.contains(Int(e.code.dropFirst(5)) ?? 0)

                if !isRetryable { throw e }
                lastError = e
            } catch {
                // Network errors are retryable
                lastError = error
            }
            if attempt < maxRetries - 1 {
                let delay = attempt < Self.delayNs.count ? Self.delayNs[attempt] : Self.delayNs.last!
                try await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError!
    }
}

// MARK: - API error body for nested error parsing

private struct ApiErrorBody: Codable {
    let error: ApiErrorInner?
    let code: String?
    let message: String?
}

private struct ApiErrorInner: Codable {
    let code: String?
    let message: String?
}

// MARK: - EIP-712 hash computation

/// Compute the EIP-712 hash for an APIRequest.
///
/// Domain: name="remit.md", version="0.1", chainId, verifyingContract
/// Struct: APIRequest(string method, string path, uint256 timestamp, bytes32 nonce)
///
/// Exposed as `internal` for golden-vector testing via @testable import.
internal func eip712Hash(
    chainId: UInt64,
    routerAddress: String,
    method: String,
    path: String,
    timestamp: UInt64,
    nonce: Data
) -> Data {
    // Type hashes (keccak256 of the type string)
    let domainTypeHash = keccak256(Data("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".utf8))
    let requestTypeHash = keccak256(Data("APIRequest(string method,string path,uint256 timestamp,bytes32 nonce)".utf8))

    // Domain separator: keccak256(domainTypeHash || nameHash || versionHash || chainId32 || contract32)
    let nameHash    = keccak256(Data("remit.md".utf8))
    let versionHash = keccak256(Data("0.1".utf8))
    let chainIdEnc  = encodeUint256(chainId)
    let contractEnc = encodeAddress(routerAddress)

    var domainData = Data()
    domainData.append(domainTypeHash)
    domainData.append(nameHash)
    domainData.append(versionHash)
    domainData.append(chainIdEnc)
    domainData.append(contractEnc)
    let domainSeparator = keccak256(domainData)

    // Struct hash: keccak256(requestTypeHash || methodHash || pathHash || timestamp32 || nonce32)
    let methodHash   = keccak256(Data(method.utf8))
    let pathHash     = keccak256(Data(path.utf8))
    let timestampEnc = encodeUint256(timestamp)
    var paddedNonce  = Data(repeating: 0, count: 32)
    let bytesToCopy  = min(nonce.count, 32)
    paddedNonce.replaceSubrange(0..<bytesToCopy, with: nonce.prefix(bytesToCopy))

    var structData = Data()
    structData.append(requestTypeHash)
    structData.append(methodHash)
    structData.append(pathHash)
    structData.append(timestampEnc)
    structData.append(paddedNonce)
    let structHash = keccak256(structData)

    // Final: keccak256(0x1901 || domainSeparator || structHash)
    var finalData = Data([0x19, 0x01])
    finalData.append(domainSeparator)
    finalData.append(structHash)
    return keccak256(finalData)
}

/// Encode a UInt64 as ABI uint256 (32-byte big-endian, zero-padded on the left).
private func encodeUint256(_ value: UInt64) -> Data {
    var result = Data(repeating: 0, count: 32)
    var v = value
    for i in stride(from: 31, through: 24, by: -1) {
        result[i] = UInt8(v & 0xFF)
        v >>= 8
    }
    return result
}

/// Encode an Ethereum address as ABI bytes32 (12 zero bytes + 20 address bytes).
private func encodeAddress(_ address: String) -> Data {
    var result = Data(repeating: 0, count: 32)
    let hex = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
    guard hex.count == 40, let addrData = Data(hexString: hex) else { return result }
    result.replaceSubrange(12..<32, with: addrData)
    return result
}

// MARK: - Mock transport

/// In-memory transport for unit tests - no network required.
internal final class MockTransport: Transport, @unchecked Sendable {
    private let mock: MockRemit

    init(mock: MockRemit) {
        self.mock = mock
    }

    func request<T: Decodable>(
        method: String,
        path: String,
        body: (any Encodable)?
    ) async throws -> T {
        return try mock.handle(method: method, path: path, body: body)
    }
}

// MARK: - Existential Encodable helper

/// Encodes an `any Encodable` value to JSON data using Swift 5.7 existential opening.
internal func encodeBody(_ body: any Encodable) throws -> Data {
    func doEncode<T: Encodable>(_ v: T) throws -> Data {
        try JSONEncoder().encode(v)
    }
    return try doEncode(body)
}
