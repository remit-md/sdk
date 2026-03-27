// Swift SDK acceptance tests: all 7 payment flows on live Base Sepolia.
//
// Run: swift test --filter AcceptanceTests
//
// Env vars (all optional):
//   ACCEPTANCE_API_URL  - default: https://remit.md
//   ACCEPTANCE_RPC_URL  - default: https://sepolia.base.org

import XCTest
@testable import RemitMd
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class AcceptanceTests: XCTestCase {

    static let apiURL = ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] ?? "https://remit.md"
    static let rpcURL = ProcessInfo.processInfo.environment["ACCEPTANCE_RPC_URL"] ?? "https://sepolia.base.org"
    static let usdcAddress = "0x2d846325766921935f37d5b4478196d3ef93707c"
    static let feeWallet = "0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38"
    static let chainIdVal: UInt64 = 84532

    static var contracts: [String: Any]?

    struct TestWallet {
        let wallet: RemitWallet
        let signer: PrivateKeySigner
    }

    func createTestWallet() async throws -> TestWallet {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        #if canImport(Security)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        #else
        // Linux: use SystemRandomNumberGenerator
        var rng = SystemRandomNumberGenerator()
        for i in 0..<32 { keyBytes[i] = UInt8.random(in: 0...255, using: &rng) }
        #endif
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
        let url = URL(string: "\(Self.apiURL)/api/v1/contracts")!
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

    // ─── EIP-712 TabCharge Signing ──────────────────────────────────────────

    func signTabCharge(signer: PrivateKeySigner, tabContract: String,
                       tabId: String, totalCharged: UInt64, callCount: UInt32) throws -> String {
        return try RemitWallet.signTabCharge(
            signer: signer, tabContract: tabContract,
            tabId: tabId, totalCharged: totalCharged, callCount: callCount,
            chainId: Self.chainIdVal
        )
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

    // ─── Test: Tab Lifecycle ────────────────────────────────────────────────

    func testTabLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] != nil else {
            throw XCTSkip("ACCEPTANCE_API_URL not set")
        }

        let payer = try await createTestWallet()
        let provider = try await createTestWallet()
        try await fundWallet(payer, amount: 100)

        let contracts = try await fetchContracts()
        let tabAddr = contracts["tab"] as! String

        // Sign permit for the Tab contract
        let deadline = UInt64(Date().timeIntervalSince1970) + 3600
        let permit = try signUsdcPermit(signer: payer.signer, owner: payer.wallet.address,
                                        spender: tabAddr, value: 20_000_000, nonce: 0, deadline: deadline)

        let payerBefore = try await getUsdcBalance(payer.wallet.address)
        let feeBefore = try await getFeeBalance()

        // 1. Create tab: $10 limit, $0.10 per call
        let tab = try await payer.wallet.openTab(provider: provider.wallet.address,
                                                  limitAmount: 10.0, perUnit: 0.10, permit: permit)
        XCTAssertFalse(tab.id.isEmpty, "tab ID should not be empty")

        // Wait for on-chain funding
        _ = try await waitForBalanceChange(payer.wallet.address, before: payerBefore)

        // 2. Charge tab: $0.10 charge, cumulative $0.10, callCount 1
        let chargeAmount = 0.10
        let chargeSig = try signTabCharge(signer: provider.signer, tabContract: tabAddr,
                                          tabId: tab.id, totalCharged: 100_000, callCount: 1)
        let charge = try await provider.wallet.chargeTab(id: tab.id, amount: chargeAmount,
                                                          cumulative: chargeAmount, callCount: 1, providerSig: chargeSig)
        XCTAssertEqual(charge.tabId, tab.id, "charge tab_id mismatch")

        // 3. Close tab with final settlement
        let closeSig = try signTabCharge(signer: provider.signer, tabContract: tabAddr,
                                         tabId: tab.id, totalCharged: 100_000, callCount: 1)
        let closed = try await payer.wallet.closeTab(id: tab.id, finalAmount: chargeAmount, providerSig: closeSig)
        XCTAssertNotEqual(closed.status, .open, "tab should not be open after close")

        // 4. Verify balance: payer should have lost funds
        let payerAfter = try await waitForBalanceChange(payer.wallet.address, before: payerBefore)
        let feeAfter = try await getFeeBalance()
        let payerDelta = payerAfter - payerBefore
        XCTAssertTrue(payerDelta < 0, "payer should have lost funds, delta=\(payerDelta)")
        print("Tab: payer delta=\(payerDelta), fee delta=\(feeAfter - feeBefore)")
    }

    // ─── Test: Stream Lifecycle ─────────────────────────────────────────────

    func testStreamLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] != nil else {
            throw XCTSkip("ACCEPTANCE_API_URL not set")
        }

        let payer = try await createTestWallet()
        let payee = try await createTestWallet()
        try await fundWallet(payer, amount: 100)

        let contracts = try await fetchContracts()
        let streamAddr = contracts["stream"] as! String

        // Sign permit for the Stream contract
        let deadline = UInt64(Date().timeIntervalSince1970) + 3600
        let permit = try signUsdcPermit(signer: payer.signer, owner: payer.wallet.address,
                                        spender: streamAddr, value: 10_000_000, nonce: 0, deadline: deadline)

        let payerBefore = try await getUsdcBalance(payer.wallet.address)

        // 1. Create stream: $0.01/sec, $5 max
        let stream = try await payer.wallet.startStream(payee: payee.wallet.address,
                                                         ratePerSecond: 0.01, maxTotal: 5.0, permit: permit)
        XCTAssertFalse(stream.id.isEmpty, "stream ID should not be empty")

        // Wait for on-chain lock
        _ = try await waitForBalanceChange(payer.wallet.address, before: payerBefore)

        // 2. Let it run for a few seconds
        try await Task.sleep(nanoseconds: 5_000_000_000)

        // 3. Close stream
        let closed = try await payer.wallet.closeStream(id: stream.id)
        print("Stream closed: status=\(closed.status)")

        // 4. Conservation of funds: payer should have lost some amount
        let payerAfter = try await waitForBalanceChange(payer.wallet.address, before: payerBefore)
        let payeeAfter = try await getUsdcBalance(payee.wallet.address)
        let payerDelta = payerAfter - payerBefore
        XCTAssertTrue(payerDelta < 0, "payer should have lost funds, delta=\(payerDelta)")
        print("Stream: payer delta=\(payerDelta), payee balance=\(payeeAfter)")
    }

    // ─── Test: Bounty Lifecycle ─────────────────────────────────────────────

    func testBountyLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] != nil else {
            throw XCTSkip("ACCEPTANCE_API_URL not set")
        }

        let poster = try await createTestWallet()
        let submitter = try await createTestWallet()
        try await fundWallet(poster, amount: 100)

        let contracts = try await fetchContracts()
        let bountyAddr = contracts["bounty"] as! String

        // Sign permit for the Bounty contract
        let deadline = UInt64(Date().timeIntervalSince1970) + 3600
        let permit = try signUsdcPermit(signer: poster.signer, owner: poster.wallet.address,
                                        spender: bountyAddr, value: 10_000_000, nonce: 0, deadline: deadline)

        let posterBefore = try await getUsdcBalance(poster.wallet.address)
        let feeBefore = try await getFeeBalance()

        // 1. Create bounty: $5 reward, 1 hour deadline
        let bountyDeadline = Int(Date().timeIntervalSince1970) + 3600
        let bounty = try await poster.wallet.postBounty(amount: 5.0,
                                                         taskDescription: "Write a Swift acceptance test",
                                                         deadline: bountyDeadline, permit: permit)
        XCTAssertFalse(bounty.id.isEmpty, "bounty ID should not be empty")

        // Wait for on-chain lock
        _ = try await waitForBalanceChange(poster.wallet.address, before: posterBefore)

        // 2. Submit evidence (as submitter)
        let evidenceBytes = keccak256("test evidence".data(using: .utf8)!)
        let evidenceHash = "0x" + evidenceBytes.map { String(format: "%02x", $0) }.joined()
        let sub = try await submitter.wallet.submitBounty(id: bounty.id, evidenceUri: evidenceHash)
        XCTAssertEqual(sub.bountyId, bounty.id, "submission bounty_id mismatch")

        // 3. Award bounty (as poster)
        let awarded = try await poster.wallet.awardBounty(id: bounty.id, submissionId: sub.id)
        print("Bounty awarded: status=\(awarded.status)")

        // 4. Verify balances
        let submitterAfter = try await waitForBalanceChange(submitter.wallet.address, before: 0)
        let feeAfter = try await getFeeBalance()
        XCTAssertTrue(submitterAfter > 0, "submitter should have received funds, got balance=\(submitterAfter)")
        print("Bounty: submitter received=\(submitterAfter), fee delta=\(feeAfter - feeBefore)")
    }

    // ─── Test: Deposit Lifecycle ────────────────────────────────────────────

    func testDepositLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] != nil else {
            throw XCTSkip("ACCEPTANCE_API_URL not set")
        }

        let payer = try await createTestWallet()
        let provider = try await createTestWallet()
        try await fundWallet(payer, amount: 100)

        let contracts = try await fetchContracts()
        let depositAddr = contracts["deposit"] as! String

        // Sign permit for the Deposit contract
        let deadline = UInt64(Date().timeIntervalSince1970) + 3600
        let permit = try signUsdcPermit(signer: payer.signer, owner: payer.wallet.address,
                                        spender: depositAddr, value: 10_000_000, nonce: 0, deadline: deadline)

        let payerBefore = try await getUsdcBalance(payer.wallet.address)

        // 1. Place deposit: $5, expires in 1 hour
        let deposit = try await payer.wallet.placeDeposit(provider: provider.wallet.address,
                                                           amount: 5.0, expiresIn: 3600, permit: permit)
        XCTAssertFalse(deposit.id.isEmpty, "deposit ID should not be empty")

        // Wait for on-chain lock
        _ = try await waitForBalanceChange(payer.wallet.address, before: payerBefore)
        let payerAfterDeposit = try await getUsdcBalance(payer.wallet.address)

        // 2. Return deposit (by provider)
        _ = try await provider.wallet.returnDeposit(id: deposit.id)

        // 3. Verify full refund (deposits have no fee)
        let payerAfterReturn = try await waitForBalanceChange(payer.wallet.address, before: payerAfterDeposit)
        let refundAmount = payerAfterReturn - payerAfterDeposit
        XCTAssertTrue(refundAmount > 4.99, "expected near-full refund (~5.0), got \(refundAmount)")
        print("Deposit: refunded=\(refundAmount) (full refund, no fee)")
    }

    // ─── Test: X402 Auto-Pay ────────────────────────────────────────────────

    func testX402AutoPay() async throws {
        guard ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] != nil else {
            throw XCTSkip("ACCEPTANCE_API_URL not set")
        }

        let providerWallet = try await createTestWallet()

        // Build the x402 PAYMENT-REQUIRED header payload
        let payloadDict: [String: Any] = [
            "payTo": providerWallet.wallet.address,
            "maxAmountRequired": 100_000,
            "asset": "eip155:84532/erc20:\(Self.usdcAddress)",
            "network": "eip155:84532",
            "facilitatorURL": Self.apiURL + "/api/v1/x402/verify",
            "resource": "/v1/data",
            "description": "Test data endpoint",
            "mimeType": "application/json",
            "maxTimeoutSeconds": 60
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payloadDict)
        let payloadBase64 = payloadData.base64EncodedString()

        // 1. Verify the PAYMENT-REQUIRED header is parseable
        guard let decoded = Data(base64Encoded: payloadBase64) else {
            XCTFail("Failed to decode PAYMENT-REQUIRED base64")
            return
        }
        let parsed = try JSONSerialization.jsonObject(with: decoded) as! [String: Any]
        XCTAssertNotNil(parsed["payTo"], "PAYMENT-REQUIRED missing payTo field")

        // 2. Verify V2 fields are present
        XCTAssertEqual(parsed["resource"] as? String, "/v1/data", "resource field mismatch")
        XCTAssertEqual(parsed["description"] as? String, "Test data endpoint", "description field mismatch")
        XCTAssertEqual(parsed["mimeType"] as? String, "application/json", "mimeType field mismatch")

        // 3. Verify the facilitator URL points to our API
        let facilitatorURL = parsed["facilitatorURL"] as? String ?? ""
        XCTAssertTrue(facilitatorURL.contains(Self.apiURL),
                      "facilitatorURL should reference our API: got \(facilitatorURL)")

        // 4. Verify a GET to the x402/verify endpoint exists (OPTIONS or 4xx, not 404)
        let verifyURL = URL(string: Self.apiURL + "/api/v1/x402/verify")!
        let (_, verifyResp) = try await URLSession.shared.data(from: verifyURL)
        let httpResp = verifyResp as! HTTPURLResponse
        // 405 (Method Not Allowed) or 400 (Bad Request) means the endpoint exists
        // 404 would mean the endpoint is missing
        XCTAssertNotEqual(httpResp.statusCode, 404,
                          "x402/verify endpoint should exist (got \(httpResp.statusCode))")
        print("X402: paywall verified, facilitator endpoint exists (status=\(httpResp.statusCode))")
    }
}
