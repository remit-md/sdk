import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RemitMd

// MARK: - MockURLProtocol

/// Custom URLProtocol that intercepts all requests and returns mock responses.
/// Used to test HttpSigner without a real HTTP server.
final class MockURLProtocol: URLProtocol {
    /// Handler closure that takes a URLRequest and returns (HTTPURLResponse, Data).
    /// Set this before running tests.
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "MockURLProtocol", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No request handler set"]
            ))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Test constants

private let mockAddress = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
private let mockSignature = "0x" + String(repeating: "ab", count: 32)
    + String(repeating: "cd", count: 32) + "1b"
private let validToken = "rmit_sk_" + String(repeating: "a1", count: 32)
private let mockURL = "http://127.0.0.1:7402"

// MARK: - Tests

final class HttpSignerTests: XCTestCase {

    /// Create a URLSession configured to use MockURLProtocol.
    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
    }

    // MARK: - Happy path

    func testCreateAndSign() throws {
        // Mock both /address and /sign/digest endpoints
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            let auth = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertEqual(auth, "Bearer \(validToken)")

            if path == "/address" && request.httpMethod == "GET" {
                let body = try JSONEncoder().encode(["address": mockAddress])
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
                return (resp, body)
            }

            if path == "/sign/digest" && request.httpMethod == "POST" {
                // Note: request.httpBody may be nil in URLProtocol-intercepted requests
                // (the body is consumed via httpBodyStream). We skip body assertions here
                // and just return the mock signature.
                let body = try JSONEncoder().encode(["signature": mockSignature])
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
                return (resp, body)
            }

            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 404,
                httpVersion: nil, headerFields: nil
            )!
            return (resp, Data("{\"error\":\"not_found\"}".utf8))
        }

        let signer = try HttpSigner(url: mockURL, token: validToken, session: mockSession())
        XCTAssertEqual(signer.address, mockAddress)

        // Sign a 32-byte digest
        let digest = Data(repeating: 0x42, count: 32)
        let sig = try signer.sign(digest: digest)
        XCTAssertEqual(sig, mockSignature)
    }

    // MARK: - 401 on create

    func testCreate401() throws {
        MockURLProtocol.requestHandler = { request in
            let body = Data("{\"error\":\"unauthorized\"}".utf8)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil
            )!
            return (resp, body)
        }

        do {
            _ = try HttpSigner(url: mockURL, token: "bad_token", session: mockSession())
            XCTFail("Expected RemitError")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.unauthorized)
            XCTAssertTrue(e.message.contains("unauthorized"))
        }
    }

    // MARK: - 403 with reason

    func testCreate403WithReason() throws {
        MockURLProtocol.requestHandler = { request in
            let body = Data("{\"error\":\"policy_denied\",\"reason\":\"IP not allowed\"}".utf8)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 403,
                httpVersion: nil, headerFields: nil
            )!
            return (resp, body)
        }

        do {
            _ = try HttpSigner(url: mockURL, token: validToken, session: mockSession())
            XCTFail("Expected RemitError")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.unauthorized)
            XCTAssertTrue(e.message.contains("policy denied"))
            XCTAssertTrue(e.message.contains("IP not allowed"))
        }
    }

    // MARK: - 500 on create

    func testCreate500() throws {
        MockURLProtocol.requestHandler = { request in
            let body = Data("{\"error\":\"internal_error\"}".utf8)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 500,
                httpVersion: nil, headerFields: nil
            )!
            return (resp, body)
        }

        do {
            _ = try HttpSigner(url: mockURL, token: validToken, session: mockSession())
            XCTFail("Expected RemitError")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.serverError)
            XCTAssertTrue(e.message.contains("500"))
        }
    }

    // MARK: - Malformed address response

    func testMalformedAddressResponse() throws {
        MockURLProtocol.requestHandler = { request in
            let body = Data("{\"notAddress\":true}".utf8)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (resp, body)
        }

        do {
            _ = try HttpSigner(url: mockURL, token: validToken, session: mockSession())
            XCTFail("Expected RemitError")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.serverError)
            XCTAssertTrue(e.message.contains("no address"))
        }
    }

    // MARK: - 401 on sign

    func testSign401() throws {
        var callCount = 0
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            callCount += 1

            if path == "/address" {
                let body = try JSONEncoder().encode(["address": mockAddress])
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
                return (resp, body)
            }

            // /sign/digest returns 401
            let body = Data("{\"error\":\"unauthorized\"}".utf8)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil
            )!
            return (resp, body)
        }

        let signer = try HttpSigner(url: mockURL, token: validToken, session: mockSession())
        XCTAssertEqual(signer.address, mockAddress)

        do {
            _ = try signer.sign(digest: Data(repeating: 0, count: 32))
            XCTFail("Expected RemitError")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.unauthorized)
        }
    }

    // MARK: - 403 on sign with reason

    func testSign403WithReason() throws {
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""

            if path == "/address" {
                let body = try JSONEncoder().encode(["address": mockAddress])
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
                return (resp, body)
            }

            // /sign/digest returns 403
            let body = Data("{\"error\":\"policy_denied\",\"reason\":\"chain not allowed\"}".utf8)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 403,
                httpVersion: nil, headerFields: nil
            )!
            return (resp, body)
        }

        let signer = try HttpSigner(url: mockURL, token: validToken, session: mockSession())

        do {
            _ = try signer.sign(digest: Data(repeating: 0, count: 32))
            XCTFail("Expected RemitError")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.unauthorized)
            XCTAssertTrue(e.message.contains("policy denied"))
            XCTAssertTrue(e.message.contains("chain not allowed"))
        }
    }

    // MARK: - 500 on sign

    func testSign500() throws {
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""

            if path == "/address" {
                let body = try JSONEncoder().encode(["address": mockAddress])
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
                return (resp, body)
            }

            let body = Data("{\"error\":\"internal_error\"}".utf8)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 500,
                httpVersion: nil, headerFields: nil
            )!
            return (resp, body)
        }

        let signer = try HttpSigner(url: mockURL, token: validToken, session: mockSession())

        do {
            _ = try signer.sign(digest: Data(repeating: 0, count: 32))
            XCTFail("Expected RemitError")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.serverError)
            XCTAssertTrue(e.message.contains("500"))
        }
    }

    // MARK: - Malformed sign response

    func testSignMalformedResponse() throws {
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""

            if path == "/address" {
                let body = try JSONEncoder().encode(["address": mockAddress])
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
                return (resp, body)
            }

            // /sign/digest returns 200 but no signature field
            let body = Data("{\"notSignature\":true}".utf8)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (resp, body)
        }

        let signer = try HttpSigner(url: mockURL, token: validToken, session: mockSession())

        do {
            _ = try signer.sign(digest: Data(repeating: 0, count: 32))
            XCTFail("Expected RemitError")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.serverError)
            XCTAssertTrue(e.message.contains("no signature"))
        }
    }

    // MARK: - Token not in description

    func testTokenNotInDescription() throws {
        MockURLProtocol.requestHandler = { request in
            let body = try JSONEncoder().encode(["address": mockAddress])
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (resp, body)
        }

        let signer = try HttpSigner(url: mockURL, token: validToken, session: mockSession())
        let desc = signer.description
        XCTAssertFalse(desc.contains(validToken),
            "Token must not appear in description, got: \(desc)")
        XCTAssertTrue(desc.contains(mockAddress),
            "Address should appear in description")
        // Also check String(describing:)
        let str = String(describing: signer)
        XCTAssertFalse(str.contains(validToken),
            "Token must not appear in String(describing:)")
    }

    // MARK: - Trailing slash in URL is handled

    func testTrailingSlashStripped() throws {
        MockURLProtocol.requestHandler = { request in
            // Verify the URL does not have double slashes
            let urlStr = request.url?.absoluteString ?? ""
            XCTAssertFalse(urlStr.contains("//address"),
                "Double slash in URL: \(urlStr)")

            let body = try JSONEncoder().encode(["address": mockAddress])
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (resp, body)
        }

        let signer = try HttpSigner(url: mockURL + "/", token: validToken, session: mockSession())
        XCTAssertEqual(signer.address, mockAddress)
    }
}
