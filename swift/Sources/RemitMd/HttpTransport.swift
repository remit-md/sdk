import Foundation

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
    private let signer: any Signer
    private let session: URLSession
    private let maxRetries = 3

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(baseURL: String, signer: any Signer) {
        self.baseURL = baseURL
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

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString

        if let body {
            req.httpBody = try encodeBody(body)
        }

        // EIP-712-style request signing
        let bodyHex = req.httpBody.map { "0x" + $0.hexString } ?? "0x"
        let sigInput = "\(method)\n\(path)\n\(timestamp)\n\(nonce)\n\(bodyHex)"
        let sigDigest = keccak256(Data(sigInput.utf8))
        let sig = try signer.sign(digest: sigDigest)

        req.setValue(signer.address, forHTTPHeaderField: "X-Remit-Address")
        req.setValue(timestamp, forHTTPHeaderField: "X-Remit-Timestamp")
        req.setValue(nonce, forHTTPHeaderField: "X-Remit-Nonce")
        req.setValue(sig, forHTTPHeaderField: "X-Remit-Signature")

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
