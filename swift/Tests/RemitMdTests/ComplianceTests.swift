import XCTest
import Foundation
@testable import RemitMd

/// Compliance tests: Swift SDK against a real running server.
///
/// Tests are skipped when the server is not reachable. Boot the server with:
///   docker compose -f docker-compose.compliance.yml up -d
///
/// Environment variables:
///   REMIT_TEST_SERVER_URL  (default: http://localhost:3000)
///   REMIT_ROUTER_ADDRESS   (default: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8)
final class ComplianceTests: XCTestCase {

    // MARK: - Config

    private static let serverURL: String = {
        ProcessInfo.processInfo.environment["REMIT_TEST_SERVER_URL"] ?? "http://localhost:3000"
    }()

    private static let routerAddress: String = {
        ProcessInfo.processInfo.environment["REMIT_ROUTER_ADDRESS"]
            ?? "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
    }()

    private static var _serverAvailable: Bool?
    private static var sharedPayerKey: String?
    private static var sharedPayerAddr: String?

    // MARK: - Availability

    private static func isServerAvailable() async -> Bool {
        if let cached = _serverAvailable { return cached }
        guard let url = URL(string: serverURL + "/health") else {
            _serverAvailable = false
            return false
        }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "GET"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            _serverAvailable = ok
            return ok
        } catch {
            _serverAvailable = false
            return false
        }
    }

    // MARK: - Helpers

    /// Makes a JSON POST/GET and decodes the response body.
    private static func httpJSON(
        method: String,
        path: String,
        body: [String: Any]? = nil,
        bearerToken: String? = nil
    ) async throws -> [String: Any] {
        let url = URL(string: serverURL + path)!
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = bearerToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// Register a new operator. Returns (privateKey, walletAddress).
    private static func registerAndGetKey() async throws -> (String, String) {
        let email = "compliance.swift.\(Int(Date().timeIntervalSince1970 * 1000))@test.remitmd.local"
        let reg = try await httpJSON(
            method: "POST",
            path: "/api/v0/auth/register",
            body: ["email": email, "password": "ComplianceTestPass1!"]
        )
        guard let token = reg["token"] as? String,
              let walletAddr = reg["wallet_address"] as? String else {
            throw NSError(domain: "Compliance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "register failed: \(reg)"])
        }
        let keyData = try await httpJSON(
            method: "GET",
            path: "/api/v0/auth/agent-key",
            bearerToken: token
        )
        guard let privateKey = keyData["private_key"] as? String else {
            throw NSError(domain: "Compliance", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "agent-key failed: \(keyData)"])
        }
        return (privateKey, walletAddr)
    }

    /// Fund a wallet via faucet (no auth required in testnet mode).
    private static func fundWallet(_ walletAddr: String) async throws {
        let resp = try await httpJSON(
            method: "POST",
            path: "/api/v0/faucet",
            body: ["wallet": walletAddr, "amount": 1000]
        )
        guard resp["tx_hash"] is String else {
            throw NSError(domain: "Compliance", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "faucet failed: \(resp)"])
        }
    }

    private static func makeWallet(privateKey: String) throws -> RemitWallet {
        try RemitWallet(
            privateKey: privateKey,
            chain: .baseSepolia,
            baseURL: serverURL,
            routerAddress: routerAddress
        )
    }

    private static func getSharedPayer() async throws -> RemitWallet {
        if let key = sharedPayerKey {
            return try makeWallet(privateKey: key)
        }
        let (pk, addr) = try await registerAndGetKey()
        try await fundWallet(addr)
        sharedPayerKey  = pk
        sharedPayerAddr = addr
        return try makeWallet(privateKey: pk)
    }

    // MARK: - Auth tests

    func testCompliance_AuthenticatedRequest_ReturnsBalance_Not401() async throws {
        guard await Self.isServerAvailable() else { return }

        let (pk, _) = try await Self.registerAndGetKey()
        let wallet = try Self.makeWallet(privateKey: pk)

        // balance() makes an authenticated GET — will throw on 401.
        let balance = try await wallet.balance()
        XCTAssertNotNil(balance)
    }

    func testCompliance_UnauthenticatedRequest_Returns401() async throws {
        guard await Self.isServerAvailable() else { return }

        let url = URL(string: Self.serverURL + "/api/v0/payments/direct")!
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "to": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
            "amount": "1.000000",
        ])
        let (_, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 401,
            "unauthenticated POST must return 401")
    }

    // MARK: - Payment tests

    func testCompliance_PayDirect_HappyPath_ReturnsTxHash() async throws {
        guard await Self.isServerAvailable() else { return }

        let payer = try await Self.getSharedPayer()
        let (_, payeeAddr) = try await Self.registerAndGetKey()

        let tx = try await payer.pay(to: payeeAddr, amount: 5.0, memo: "swift compliance test")

        XCTAssertFalse(tx.txHash?.isEmpty ?? true,
            "pay() must return a non-empty txHash")
    }

    func testCompliance_PayDirect_BelowMinimum_ThrowsError() async throws {
        guard await Self.isServerAvailable() else { return }

        let payer = try await Self.getSharedPayer()
        let (_, payeeAddr) = try await Self.registerAndGetKey()

        do {
            _ = try await payer.pay(to: payeeAddr, amount: 0.0001)
            XCTFail("pay() with amount below minimum must throw an error")
        } catch {
            // Expected — any error is acceptable.
        }
    }
}
