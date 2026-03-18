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

final class AcceptanceTests: XCTestCase {

    static let apiURL = ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] ?? "https://remit.md"
    static let rpcURL = ProcessInfo.processInfo.environment["ACCEPTANCE_RPC_URL"] ?? "https://sepolia.base.org"
    static let usdcAddress = "0x142aD61B8d2edD6b3807D9266866D97C35Ee0317"
    static let feeWallet = "0xd3f721BDF92a2bB5Dd8d2FE2AFC03aFE5629B420"
    static let chainIdVal: UInt64 = 84532

    static var contracts: [String: Any]?

    struct TestWallet {
        let wallet: RemitWallet
        let signer: PrivateKeySigner
    }

    func createTestWallet() async throws -> TestWallet {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        let hexKey = "0x" + keyBytes.map { String(format: "%02x", $0) }.joined()

        let contracts = try await fetchContracts()
        let routerAddress = contracts["router"] as? String ?? ""

        let signer = try PrivateKeySigner(privateKey: hexKey)
        let wallet = try RemitWallet(privateKey: hexKey, chain: .baseSepolia,
                                     baseURL: Self.apiURL, routerAddress: routerAddress)
        return TestWallet(wallet: wallet, signer: signer)
    }

    func fetchContracts() async throws -> [String: Any] {
        if let cached = Self.contracts { return cached }
        let url = URL(string: "\(Self.apiURL)/api/v0/contracts")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        let httpResp = resp as! HTTPURLResponse
        guard httpResp.statusCode == 200 else {
            throw RemitError(RemitError.serverError, "GET /contracts: \(httpResp.statusCode)")
        }
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        Self.contracts = json
        return json
    }

    func getUsdcBalance(_ address: String) async throws -> Double {
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

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let resultHex = (json["result"] as? String ?? "0x0").replacingOccurrences(of: "0x", with: "")
        let raw = UInt64(resultHex, radix: 16) ?? 0
        return Double(raw) / 1_000_000.0
    }

    func getFeeBalance() async throws -> Double {
        try await getUsdcBalance(Self.feeWallet)
    }

    func waitForBalanceChange(_ address: String, before: Double, timeout: TimeInterval = 30) async throws -> Double {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = try await getUsdcBalance(address)
            if abs(current - before) > 0.0001 { return current }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return try await getUsdcBalance(address)
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
        _ = try await waitForBalanceChange(tw.wallet.address, before: 0)
    }

    // ─── EIP-2612 Permit Signing ──────────────────────────────────────────

    func signUsdcPermit(signer: PrivateKeySigner, owner: String, spender: String,
                        value: UInt64, nonce: UInt64, deadline: UInt64) throws -> PermitSignature {
        let domainTypeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".data(using: .utf8)!)
        let nameHash = keccak256("USD Coin".data(using: .utf8)!)
        let versionHash = keccak256("2".data(using: .utf8)!)

        var domainData = Data()
        domainData.append(domainTypeHash)
        domainData.append(nameHash)
        domainData.append(versionHash)
        domainData.append(padUint256(Self.chainIdVal))
        domainData.append(padAddress(Self.usdcAddress))
        let domainSep = keccak256(domainData)

        let permitTypeHash = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)".data(using: .utf8)!)
        var structData = Data()
        structData.append(permitTypeHash)
        structData.append(padAddress(owner))
        structData.append(padAddress(spender))
        structData.append(padUint256(value))
        structData.append(padUint256(nonce))
        structData.append(padUint256(deadline))
        let structHash = keccak256(structData)

        var finalData = Data([0x19, 0x01])
        finalData.append(domainSep)
        finalData.append(structHash)
        let digest = keccak256(finalData)

        let sigHex = try signer.sign(digest: digest)
        let sigClean = sigHex.hasPrefix("0x") ? String(sigHex.dropFirst(2)) : sigHex
        let sigBytes = dataFromHex(sigClean)

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
        let bytes = dataFromHex(hex)
        var data = Data(repeating: 0, count: 32)
        data.replaceSubrange(12..<32, with: bytes)
        return data
    }

    func dataFromHex(_ hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        return data
    }

    // ─── Tests ──────────────────────────────────────────────────────────────

    func testPayDirectWithPermit() async throws {
        guard ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] != nil else {
            throw XCTSkip("ACCEPTANCE_API_URL not set")
        }

        let agent = try await createTestWallet()
        let provider = try await createTestWallet()
        try await fundWallet(agent, amount: 100)

        let amount = 1.0
        let fee = 0.01
        let providerReceives = amount - fee

        let agentBefore = try await getUsdcBalance(agent.wallet.address)
        let providerBefore = try await getUsdcBalance(provider.wallet.address)
        let feeBefore = try await getFeeBalance()

        let contracts = try await fetchContracts()
        let routerAddr = contracts["router"] as! String
        let deadline = UInt64(Date().timeIntervalSince1970) + 3600
        let permit = try signUsdcPermit(signer: agent.signer, owner: agent.wallet.address,
                                        spender: routerAddr, value: 2_000_000, nonce: 0, deadline: deadline)

        let tx = try await agent.wallet.pay(to: provider.wallet.address, amount: 1.0,
                                            memo: "swift-sdk-acceptance", permit: permit)
        XCTAssertTrue(tx.txHash?.hasPrefix("0x") == true)

        let agentAfter = try await waitForBalanceChange(agent.wallet.address, before: agentBefore)
        let providerAfter = try await getUsdcBalance(provider.wallet.address)
        let feeAfter = try await getFeeBalance()

        assertBalanceChange("agent", before: agentBefore, after: agentAfter, expected: -amount)
        assertBalanceChange("provider", before: providerBefore, after: providerAfter, expected: providerReceives)
        assertBalanceChange("fee wallet", before: feeBefore, after: feeAfter, expected: fee)
    }

    func testEscrowLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] != nil else {
            throw XCTSkip("ACCEPTANCE_API_URL not set")
        }

        let agent = try await createTestWallet()
        let provider = try await createTestWallet()
        try await fundWallet(agent, amount: 100)

        let amount = 5.0
        let fee = amount * 0.01
        let providerReceives = amount - fee

        let agentBefore = try await getUsdcBalance(agent.wallet.address)
        let providerBefore = try await getUsdcBalance(provider.wallet.address)
        let feeBefore = try await getFeeBalance()

        let contracts = try await fetchContracts()
        let escrowAddr = contracts["escrow"] as! String
        let deadline = UInt64(Date().timeIntervalSince1970) + 3600
        let permit = try signUsdcPermit(signer: agent.signer, owner: agent.wallet.address,
                                        spender: escrowAddr, value: 6_000_000, nonce: 0, deadline: deadline)

        let escrow = try await agent.wallet.createEscrow(recipient: provider.wallet.address,
                                                          amount: 5.0, permit: permit)
        XCTAssertFalse(escrow.id.isEmpty)

        _ = try await waitForBalanceChange(agent.wallet.address, before: agentBefore)

        _ = try await provider.wallet.claimStart(id: escrow.id)
        try await Task.sleep(nanoseconds: 5_000_000_000)

        _ = try await agent.wallet.releaseEscrow(id: escrow.id)

        let providerAfter = try await waitForBalanceChange(provider.wallet.address, before: providerBefore)
        let feeAfter = try await getFeeBalance()
        let agentAfter = try await getUsdcBalance(agent.wallet.address)

        assertBalanceChange("agent", before: agentBefore, after: agentAfter, expected: -amount)
        assertBalanceChange("provider", before: providerBefore, after: providerAfter, expected: providerReceives)
        assertBalanceChange("fee wallet", before: feeBefore, after: feeAfter, expected: fee)
    }
}
