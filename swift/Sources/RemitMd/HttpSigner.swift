import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Signer backed by a local HTTP signing server.
///
/// Delegates EIP-712 signing to an HTTP server on localhost (typically
/// `http://127.0.0.1:7402`). The signer server holds the encrypted key;
/// this adapter only needs a bearer token and URL.
///
/// - Bearer token is stored privately, never exposed in description/debug output.
/// - Address is fetched and cached at construction time (GET /address).
/// - `sign(digest:)` POSTs to /sign/digest and returns the hex signature.
/// - All errors are explicit -- no silent fallbacks.
///
/// ```swift
/// let signer = try HttpSigner(url: "http://127.0.0.1:7402", token: "rmit_sk_...")
/// let wallet = RemitWallet(signer: signer, chain: .base)
/// ```
public final class HttpSigner: Signer, @unchecked Sendable {
    public let address: String

    private let url: String
    private let token: String
    private let session: URLSession

    // MARK: - JSON response types

    private struct AddressResponse: Decodable {
        let address: String
    }

    private struct SignatureResponse: Decodable {
        let signature: String?
    }

    private struct ErrorResponse: Decodable {
        let error: String?
        let reason: String?
    }

    // MARK: - Init

    /// Create an HttpSigner, fetching and caching the wallet address from the signer server.
    ///
    /// This constructor is synchronous (required by the `Signer` protocol) and uses
    /// `DispatchSemaphore` to block on the address fetch. This is acceptable for
    /// localhost calls (<1ms latency).
    ///
    /// - Parameters:
    ///   - url: Signer server URL (e.g., "http://127.0.0.1:7402").
    ///   - token: Bearer token for authentication.
    ///   - session: URLSession to use (default: `.shared`). Override in tests.
    /// - Throws: `RemitError` on network errors, auth failures, or missing address.
    public init(url: String, token: String, session: URLSession = .shared) throws {
        self.url = url.hasSuffix("/") ? String(url.dropLast()) : url
        self.token = token
        self.session = session

        // Fetch address synchronously using DispatchSemaphore.
        var request = URLRequest(url: URL(string: self.url + "/address")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (data, response) = try HttpSigner.syncRequest(request, session: session)
        let http = response as! HTTPURLResponse

        if http.statusCode == 401 {
            throw RemitError(RemitError.unauthorized,
                "HttpSigner: unauthorized -- check your REMIT_SIGNER_TOKEN")
        }
        if http.statusCode == 403 {
            let reason = HttpSigner.parseErrorReason(data)
            throw RemitError(RemitError.unauthorized,
                "HttpSigner: policy denied -- \(reason)")
        }
        guard http.statusCode == 200 else {
            let reason = HttpSigner.parseErrorReason(data)
            throw RemitError(RemitError.serverError,
                "HttpSigner: GET /address failed (\(http.statusCode)): \(reason)")
        }

        guard let addrResp = try? JSONDecoder().decode(AddressResponse.self, from: data),
              !addrResp.address.isEmpty else {
            throw RemitError(RemitError.serverError,
                "HttpSigner: GET /address returned no address")
        }

        self.address = addrResp.address
    }

    // MARK: - Signer protocol

    /// Sign a 32-byte digest by sending it to POST /sign/digest on the signer server.
    ///
    /// - Parameter digest: 32-byte EIP-712 digest.
    /// - Returns: Hex-encoded 65-byte ECDSA signature (r+s+v).
    /// - Throws: `RemitError` on network errors, auth failures, or invalid response.
    public func sign(digest: Data) throws -> String {
        let digestHex = "0x" + digest.hexString

        let body = try JSONEncoder().encode(["digest": digestHex])

        var request = URLRequest(url: URL(string: url + "/sign/digest")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 10

        let (data, response) = try HttpSigner.syncRequest(request, session: session)
        let http = response as! HTTPURLResponse

        if http.statusCode == 401 {
            throw RemitError(RemitError.unauthorized,
                "HttpSigner: unauthorized -- check your REMIT_SIGNER_TOKEN")
        }
        if http.statusCode == 403 {
            let reason = HttpSigner.parseErrorReason(data)
            throw RemitError(RemitError.unauthorized,
                "HttpSigner: policy denied -- \(reason)")
        }
        guard http.statusCode == 200 else {
            let reason = HttpSigner.parseErrorReason(data)
            throw RemitError(RemitError.serverError,
                "HttpSigner: POST /sign/digest failed (\(http.statusCode)): \(reason)")
        }

        guard let sigResp = try? JSONDecoder().decode(SignatureResponse.self, from: data),
              let signature = sigResp.signature, !signature.isEmpty else {
            throw RemitError(RemitError.serverError,
                "HttpSigner: server returned no signature")
        }

        return signature
    }

    // MARK: - CustomStringConvertible (no token leakage)

    /// Safe description that never includes the bearer token.
    public var description: String {
        "HttpSigner(address: \(address))"
    }

    // MARK: - Synchronous HTTP helper

    /// Execute a URLRequest synchronously using DispatchSemaphore.
    /// This blocks the calling thread until the response arrives.
    private static func syncRequest(
        _ request: URLRequest,
        session: URLSession
    ) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?

        session.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let error = resultError {
            throw RemitError(RemitError.networkError,
                "HttpSigner: cannot reach signer server at \(request.url?.host ?? "unknown"): \(error.localizedDescription)")
        }
        guard let data = resultData, let response = resultResponse else {
            throw RemitError(RemitError.networkError,
                "HttpSigner: no response from signer server")
        }
        return (data, response)
    }

    // MARK: - Error parsing helper

    /// Extract a human-readable reason from an error response body.
    private static func parseErrorReason(_ data: Data) -> String {
        guard let errResp = try? JSONDecoder().decode(ErrorResponse.self, from: data) else {
            return String(data: data, encoding: .utf8) ?? "unknown"
        }
        return errResp.reason ?? errResp.error ?? "unknown"
    }
}
