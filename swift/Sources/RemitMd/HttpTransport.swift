import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Transport protocol

/// HTTP transport layer. Inject ``MockTransport`` in tests, ``HttpTransport`` in production.
internal protocol Transport: Sendable {
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
        d.dateDecodingStrategy = .iso8601
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
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("remitmd-swift/0.1.0", forHTTPHeaderField: "User-Agent")

        if let body {
            req.httpBody = try encodeBody(body)
        }

        // Generate 32-byte random nonce
        var nonceBytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&nonceBytes, 32)
        let nonceData = Data(nonceBytes)
        let nonceHex = "0x" + nonceData.hexString

        // Unix epoch timestamp in seconds
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // EIP-712 hash and ECDSA signature
        let digest = eip712Hash(
            chainId: chainId,
            routerAddress: routerAddress,
            method: method,
            path: path,
            timestamp: timestamp,
            nonce: nonceData
        )
        let sig = try signer.sign(digest: digest)

        req.setValue(signer.address, forHTTPHeaderField: "X-Remit-Agent")
        req.setValue(nonceHex, forHTTPHeaderField: "X-Remit-Nonce")
        req.setValue(String(timestamp), forHTTPHeaderField: "X-Remit-Timestamp")
        req.setValue(sig, forHTTPHeaderField: "X-Remit-Signature")

        // Add idempotency key for mutating requests (generated once, stable across retries).
        if method == "POST" || method == "PUT" || method == "PATCH" {
            req.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Idempotency-Key")
        }

        return try await withRetry(maxRetries: maxRetries) {
            let (data, response) = try await self.session.data(for: req)
            let http = response as! HTTPURLResponse

            if http.statusCode == 200 || http.statusCode == 201 {
                return try Self.decoder.decode(T.self, from: data)
            }

            // Parse error body
            if let errJSON = try? JSONDecoder().decode([String: String].self, from: data),
               let code = errJSON["code"], let message = errJSON["message"] {
                throw RemitError(code, message)
            }

            if http.statusCode == 429 {
                throw RemitError(RemitError.rateLimited, "too many requests — back off and retry")
            }
            if http.statusCode == 401 {
                throw RemitError(RemitError.unauthorized, "invalid or missing EIP-712 signature")
            }
            throw RemitError(RemitError.serverError, "HTTP \(http.statusCode)")
        }
    }

    private func withRetry<T>(maxRetries: Int, fn: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                return try await fn()
            } catch let e as RemitError {
                // Don't retry client errors
                if [RemitError.invalidAddress, RemitError.invalidAmount,
                    RemitError.unauthorized, RemitError.signatureInvalid,
                    RemitError.nonceReused].contains(e.code) { throw e }
                lastError = e
            } catch {
                lastError = error
            }
            if attempt < maxRetries - 1 {
                let delay = UInt64(pow(2.0, Double(attempt)) * 0.5 * 1_000_000_000)
                try await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError!
    }
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

/// In-memory transport for unit tests — no network required.
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
