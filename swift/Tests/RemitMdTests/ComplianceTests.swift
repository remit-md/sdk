import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
            print("[COMPLIANCE] server availability check: invalid URL")
            _serverAvailable = false
            return false
        }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "GET"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            _serverAvailable = ok
            print("[COMPLIANCE] server availability: \(ok ? "REACHABLE" : "UNREACHABLE") at \(serverURL)")
            return ok
        } catch {
            _serverAvailable = false
            print("[COMPLIANCE] server availability: UNREACHABLE at \(serverURL) error=\(error.localizedDescription)")
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

    /// Generate a random private key and derive the wallet address.
    private static func generateWallet() throws -> (String, String) {
        let keyBytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let privateKey = "0x" + keyBytes.map { String(format: "%02x", $0) }.joined()
        let wallet = try makeWallet(privateKey: privateKey)
        print("[COMPLIANCE] wallet created: \(wallet.address) (chain=84532)")
        return (privateKey, wallet.address)
    }

    /// Fund a wallet via mint (no auth required in testnet mode).
    private static func fundWallet(_ walletAddr: String) async throws {
        print("[COMPLIANCE] mint: requesting 1000 USDC -> \(walletAddr)")
        let resp = try await httpJSON(
            method: "POST",
            path: "/api/v1/mint",
            body: ["wallet": walletAddr, "amount": 1000]
        )
        guard let txHash = resp["tx_hash"] as? String else {
            print("[COMPLIANCE] mint: FAILED for \(walletAddr) response=\(resp)")
            throw NSError(domain: "Compliance", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "mint failed: \(resp)"])
        }
        print("[COMPLIANCE] mint: 1000 USDC -> \(walletAddr) tx=\(txHash)")
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
            print("[COMPLIANCE] reusing shared payer: \(sharedPayerAddr ?? "unknown")")
            return try makeWallet(privateKey: key)
        }
        let (pk, addr) = try generateWallet()
        try await fundWallet(addr)
        sharedPayerKey  = pk
        sharedPayerAddr = addr
        print("[COMPLIANCE] shared payer initialized: \(addr)")
        return try makeWallet(privateKey: pk)
    }

    // MARK: - Auth tests

    func testCompliance_AuthenticatedRequest_ReturnsBalance_Not401() async throws {
        print("[COMPLIANCE] === test: AuthenticatedRequest_ReturnsBalance_Not401 ===")
        guard await Self.isServerAvailable() else {
            print("[COMPLIANCE] SKIPPED: server not available")
            return
        }

        let (pk, _) = try Self.generateWallet()
        let wallet = try Self.makeWallet(privateKey: pk)
        print("[COMPLIANCE] requesting balance for \(wallet.address)")

        // balance() makes an authenticated GET - will throw on 401.
        let balance = try await wallet.balance()
        print("[COMPLIANCE] balance: \(balance.balance) \(balance.currency) for \(balance.address)")
        XCTAssertNotNil(balance)
    }

    func testCompliance_UnauthenticatedRequest_Returns401() async throws {
        print("[COMPLIANCE] === test: UnauthenticatedRequest_Returns401 ===")
        guard await Self.isServerAvailable() else {
            print("[COMPLIANCE] SKIPPED: server not available")
            return
        }

        let url = URL(string: Self.serverURL + "/api/v1/payments/direct")!
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "to": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
            "amount": "1.000000",
        ])
        print("[COMPLIANCE] sending unauthenticated POST to /api/v1/payments/direct")
        let (_, resp) = try await URLSession.shared.data(for: req)
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
        print("[COMPLIANCE] unauthenticated response: status=\(statusCode)")
        XCTAssertEqual(statusCode, 401,
            "unauthenticated POST must return 401")
    }

    // MARK: - Payment tests

    func testCompliance_PayDirect_HappyPath_ReturnsTxHash() async throws {
        print("[COMPLIANCE] === test: PayDirect_HappyPath_ReturnsTxHash ===")
        guard await Self.isServerAvailable() else {
            print("[COMPLIANCE] SKIPPED: server not available")
            return
        }

        let payer = try await Self.getSharedPayer()
        let (_, payeeAddr) = try Self.generateWallet()
        print("[COMPLIANCE] pay: 5.0 USDC \(payer.address) -> \(payeeAddr) memo=\"swift compliance test\"")

        let tx = try await payer.pay(to: payeeAddr, amount: 5.0, memo: "swift compliance test")
        print("[COMPLIANCE] pay: 5.0 USDC \(payer.address) -> \(payeeAddr) tx=\(tx.txHash ?? "nil") invoice=\(tx.invoiceId ?? "nil") status=\(tx.status)")

        XCTAssertFalse(tx.txHash?.isEmpty ?? true,
            "pay() must return a non-empty txHash")
    }

    func testCompliance_PayDirect_BelowMinimum_ThrowsError() async throws {
        print("[COMPLIANCE] === test: PayDirect_BelowMinimum_ThrowsError ===")
        guard await Self.isServerAvailable() else {
            print("[COMPLIANCE] SKIPPED: server not available")
            return
        }

        let payer = try await Self.getSharedPayer()
        let (_, payeeAddr) = try Self.generateWallet()
        print("[COMPLIANCE] pay: 0.0001 USDC \(payer.address) -> \(payeeAddr) (expecting error)")

        do {
            _ = try await payer.pay(to: payeeAddr, amount: 0.0001)
            XCTFail("pay() with amount below minimum must throw an error")
        } catch {
            print("[COMPLIANCE] pay below minimum: correctly threw error: \(error)")
            // Expected - any error is acceptable.
        }
    }
}
