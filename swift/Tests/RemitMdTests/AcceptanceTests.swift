// Swift SDK acceptance tests: payDirect + escrow lifecycle on live Base Sepolia.
//
// Run: swift test --filter AcceptanceTests
//
// Env vars (all optional):
//   ACCEPTANCE_API_URL  — default: https://remit.md
//   ACCEPTANCE_RPC_URL  — default: https://sepolia.base.org

import XCTest
@testable import RemitMd
import Foundation

// Only run in CI when ACCEPTANCE_API_URL is explicitly set
// (prevents accidental live-API calls during normal development).
final class AcceptanceTests: XCTestCase {

    static let apiURL = ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] ?? "https://remit.md"
    static let rpcURL = ProcessInfo.processInfo.environment["ACCEPTANCE_RPC_URL"] ?? "https://sepolia.base.org"
    static let usdcAddress = "0x142aD61B8d2edD6b3807D9266866D97C35Ee0317"
    static let feeWallet = "0xd3f721BDF92a2bB5Dd8d2FE2AFC03aFE5629B420"
    static let chainId: UInt64 = 84532

    // Cache contracts across tests
    static var contracts: [String: Any]?

    // ─── Helpers ────────────────────────────────────────────────────────────

    struct TestWallet {
        let wallet: RemitWallet
        let signer: PrivateKeySigner
    }

    func createTestWallet() throws -> TestWallet {
        // Generate random 32-byte key
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        precondition(status == errSecSuccess)
        let hexKey = "0x" + keyBytes.map { String(format: "%02x", $0) }.joined()

        let contracts = try fetchContracts()
        let routerAddress = contracts["router"] as? String ?? ""

        let signer = try PrivateKeySigner(privateKey: hexKey)
        let wallet = try RemitWallet(privateKey: hexKey, chain: .baseSepolia,
                                     baseURL: Self.apiURL, routerAddress: routerAddress)
        return TestWallet(wallet: wallet, signer: signer)
    }

    func fetchContracts() throws -> [String: Any] {
        if let cached = Self.contracts { return cached }
        let url = URL(string: "\(Self.apiURL)/api/v0/contracts")!
        let (data, resp) = try await { (completion: @escaping (Result<(Data, URLResponse), Error>) -> Void) in
            URLSession.shared.dataTask(with: url) { d, r, e in
                if let e = e { completion(.failure(e)); return }
                completion(.success((d!, r!)))
            }.resume()
        }
        let httpResp = resp as! HTTPURLResponse
        guard httpResp.statusCode == 200 else {
            throw RemitError(RemitError.serverError, "GET /contracts: \(httpResp.statusCode)")
        }
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        Self.contracts = json
        return json
    }

    // Async-await wrapper for the old completion handler API
    func await<T>(block: @escaping (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        block { r in result = r; semaphore.signal() }
        semaphore.wait()
        return try result!.get()
    }

    func getUsdcBalance(_ address: String) throws -> Double {
        let hex = address.lowercased().replacingOccurrences(of: "0x", with: "")
        let padded = String(repeating: "0", count: 64 - hex.count) + hex
        let callData = "0x70a08231" + padded

        let body = """
        {"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"\(Self.usdcAddress)","data":"\(callData)"},"latest"]}
        """

        var request = URLRequest(url: URL(string: Self.rpcURL)!)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, _) = try self.await { (completion: @escaping (Result<(Data, URLResponse), Error>) -> Void) in
            URLSession.shared.dataTask(with: request) { d, r, e in
                if let e = e { completion(.failure(e)); return }
                completion(.success((d!, r!)))
            }.resume()
        }
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let resultHex = (json["result"] as? String ?? "0x0").replacingOccurrences(of: "0x", with: "")
        let raw = UInt64(resultHex, radix: 16) ?? 0
        return Double(raw) / 1_000_000.0
    }

    func getFeeBalance() throws -> Double {
        try getUsdcBalance(Self.feeWallet)
    }

    func waitForBalanceChange(_ address: String, before: Double, timeout: TimeInterval = 30) throws -> Double {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = try getUsdcBalance(address)
            if abs(current - before) > 0.0001 { return current }
            Thread.sleep(forTimeInterval: 2)
        }
        return try getUsdcBalance(address)
    }

    func assertBalanceChange(_ label: String, before: Double, after: Double, expected: Double,
                             file: StaticString = #file, line: UInt = #line) {
        let actual = after - before
        let tolerance = max(abs(expected) * 0.001, 0.02)
        XCTAssertTrue(abs(actual - expected) <= tolerance,
                      "\(label): expected delta \(expected), got \(actual) (before=\(before), after=\(after))",
                      file: file, line: line)
    }

    func fundWallet(_ tw: TestWallet, amount: Double) async throws {
        _ = try await tw.wallet.mint(amount: amount)
        _ = try waitForBalanceChange(tw.wallet.address, before: 0)
    }

    // ─── EIP-2612 Permit Signing ──────────────────────────────────────────

    func signUsdcPermit(signer: PrivateKeySigner, owner: String, spender: String,
                        value: UInt64, nonce: UInt64, deadline: UInt64) throws -> PermitSignature {
        // Domain separator
        let domainTypeHash = Keccak.digest("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".data(using: .utf8)!)
        let nameHash = Keccak.digest("USD Coin".data(using: .utf8)!)
        let versionHash = Keccak.digest("2".data(using: .utf8)!)

        var domainData = Data()
        domainData.append(domainTypeHash)
        domainData.append(nameHash)
        domainData.append(versionHash)
        domainData.append(padUint256(Self.chainId))
        domainData.append(padAddress(Self.usdcAddress))
        let domainSep = Keccak.digest(domainData)

        // Permit struct hash
        let permitTypeHash = Keccak.digest("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)".data(using: .utf8)!)
        var structData = Data()
        structData.append(permitTypeHash)
        structData.append(padAddress(owner))
        structData.append(padAddress(spender))
        structData.append(padUint256(value))
        structData.append(padUint256(nonce))
        structData.append(padUint256(deadline))
        let structHash = Keccak.digest(structData)

        // EIP-712 digest
        var finalData = Data([0x19, 0x01])
        finalData.append(domainSep)
        finalData.append(structHash)
        let digest = Keccak.digest(finalData)

        // Sign using SDK's signer
        let sigHex = try signer.sign(digest: digest)
        let sigBytes = Data(hexString: String(sigHex.dropFirst(2)))!

        let r = "0x" + sigBytes[0..<32].map { String(format: "%02x", $0) }.joined()
        let s = "0x" + sigBytes[32..<64].map { String(format: "%02x", $0) }.joined()
        let v = Int(sigBytes[64])

        return PermitSignature(value: Double(value), deadline: Int(deadline), v: v, r: r, s: s)
    }

    func padUint256(_ value: UInt64) -> Data {
        var data = Data(repeating: 0, count: 32)
        var val = value.bigEndian
        withUnsafeBytes(of: &val) { bytes in
            data.replaceSubrange(24..<32, with: bytes)
        }
        return data
    }

    func padAddress(_ address: String) -> Data {
        let hex = address.replacingOccurrences(of: "0x", with: "")
        let bytes = Data(hexString: hex)!
        var data = Data(repeating: 0, count: 32)
        data.replaceSubrange(12..<32, with: bytes)
        return data
    }

    // ─── Tests ──────────────────────────────────────────────────────────────

    func testPayDirectWithPermit() async throws {
        // Skip if not running in acceptance mode
        guard ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] != nil else {
            throw XCTSkip("ACCEPTANCE_API_URL not set — skipping live acceptance test")
        }

        let agent = try createTestWallet()
        let provider = try createTestWallet()
        try await fundWallet(agent, amount: 100)

        let amount = 1.0
        let fee = 0.01
        let providerReceives = amount - fee

        let agentBefore = try getUsdcBalance(agent.wallet.address)
        let providerBefore = try getUsdcBalance(provider.wallet.address)
        let feeBefore = try getFeeBalance()

        let contracts = try fetchContracts()
        let routerAddr = contracts["router"] as! String
        let deadline = UInt64(Date().timeIntervalSince1970) + 3600
        let permit = try signUsdcPermit(signer: agent.signer, owner: agent.wallet.address,
                                        spender: routerAddr, value: 2_000_000, nonce: 0, deadline: deadline)

        let tx = try await agent.wallet.pay(to: provider.wallet.address, amount: 1.0,
                                            memo: "swift-sdk-acceptance", permit: permit)
        XCTAssertTrue(tx.txHash.hasPrefix("0x"))

        let agentAfter = try waitForBalanceChange(agent.wallet.address, before: agentBefore)
        let providerAfter = try getUsdcBalance(provider.wallet.address)
        let feeAfter = try getFeeBalance()

        assertBalanceChange("agent", before: agentBefore, after: agentAfter, expected: -amount)
        assertBalanceChange("provider", before: providerBefore, after: providerAfter, expected: providerReceives)
        assertBalanceChange("fee wallet", before: feeBefore, after: feeAfter, expected: fee)
    }

    func testEscrowLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] != nil else {
            throw XCTSkip("ACCEPTANCE_API_URL not set — skipping live acceptance test")
        }

        let agent = try createTestWallet()
        let provider = try createTestWallet()
        try await fundWallet(agent, amount: 100)

        let amount = 5.0
        let fee = amount * 0.01
        let providerReceives = amount - fee

        let agentBefore = try getUsdcBalance(agent.wallet.address)
        let providerBefore = try getUsdcBalance(provider.wallet.address)
        let feeBefore = try getFeeBalance()

        let contracts = try fetchContracts()
        let escrowAddr = contracts["escrow"] as! String
        let deadline = UInt64(Date().timeIntervalSince1970) + 3600
        let permit = try signUsdcPermit(signer: agent.signer, owner: agent.wallet.address,
                                        spender: escrowAddr, value: 6_000_000, nonce: 0, deadline: deadline)

        let escrow = try await agent.wallet.createEscrow(recipient: provider.wallet.address,
                                                          amount: 5.0, permit: permit)
        XCTAssertFalse(escrow.id.isEmpty)

        _ = try waitForBalanceChange(agent.wallet.address, before: agentBefore)

        _ = try await provider.wallet.claimStart(id: escrow.id)
        try await Task.sleep(nanoseconds: 5_000_000_000)

        _ = try await agent.wallet.releaseEscrow(id: escrow.id)

        let providerAfter = try waitForBalanceChange(provider.wallet.address, before: providerBefore)
        let feeAfter = try getFeeBalance()
        let agentAfter = try getUsdcBalance(agent.wallet.address)

        assertBalanceChange("agent", before: agentBefore, after: agentAfter, expected: -amount)
        assertBalanceChange("provider", before: providerBefore, after: providerAfter, expected: providerReceives)
        assertBalanceChange("fee wallet", before: feeBefore, after: feeAfter, expected: fee)
    }
}

// ─── Hex Data helper ────────────────────────────────────────────────────────

private extension Data {
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: "0x", with: "")
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
