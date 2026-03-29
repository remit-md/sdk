// Swift SDK acceptance tests: all 9 payment flows on live Base Sepolia.
//
// Run: swift test --filter AcceptanceTests
//
// Env vars (all optional):
//   ACCEPTANCE_API_URL  - default: https://testnet.remit.md
//   ACCEPTANCE_RPC_URL  - default: https://sepolia.base.org

import XCTest
@testable import RemitMd
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class AcceptanceTests: XCTestCase {

    // MARK: - Shared state

    static let apiURL = ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] ?? "https://testnet.remit.md"
    static let rpcURL = ProcessInfo.processInfo.environment["ACCEPTANCE_RPC_URL"] ?? "https://sepolia.base.org"

    static var agentWallet: RemitWallet!
    static var agentSigner: PrivateKeySigner!
    static var providerWallet: RemitWallet!
    static var providerSigner: PrivateKeySigner!
    static var contracts: ContractAddresses!

    // MARK: - One-time setup

    override class func setUp() {
        super.setUp()
        guard ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] != nil else { return }

        let group = DispatchGroup()
        var setupError: Error?

        group.enter()
        Task {
            do {
                // Fetch contracts
                let url = URL(string: "\(apiURL)/api/v1/contracts")!
                let (data, resp) = try await URLSession.shared.data(from: url)
                let httpResp = resp as! HTTPURLResponse
                guard httpResp.statusCode == 200 else {
                    throw RemitError(RemitError.serverError, "GET /contracts: \(httpResp.statusCode)")
                }
                contracts = try JSONDecoder().decode(ContractAddresses.self, from: data)
                let routerAddr = contracts.router

                // Create agent wallet
                let (agentKey, agentSign) = try generateWallet()
                agentSigner = agentSign
                agentWallet = try RemitWallet(privateKey: agentKey, chain: .baseSepolia,
                                               baseURL: apiURL, routerAddress: routerAddr)
                print("[ACCEPTANCE] agent: \(agentWallet.address) (chain=84532)")

                // Create provider wallet
                let (providerKey, providerSign) = try generateWallet()
                providerSigner = providerSign
                providerWallet = try RemitWallet(privateKey: providerKey, chain: .baseSepolia,
                                                  baseURL: apiURL, routerAddress: routerAddr)
                print("[ACCEPTANCE] provider: \(providerWallet.address) (chain=84532)")

                // Fund agent with 100 USDC
                print("[ACCEPTANCE] mint: 100 USDC -> \(agentWallet.address)")
                let mintResult = try await agentWallet.mint(amount: 100)
                print("[ACCEPTANCE] mint | tx=\(mintResult.txHash)")
                _ = try await waitForBalanceChange(agentWallet.address, before: 0, timeout: 60)
                let bal = try await getUsdcBalance(agentWallet.address)
                print("[ACCEPTANCE] agent funded: \(bal) USDC")
            } catch {
                setupError = error
            }
            group.leave()
        }
        group.wait()
        if let err = setupError {
            fatalError("[ACCEPTANCE] setup failed: \(err)")
        }
    }

    // MARK: - Helpers

    private static func generateWallet() throws -> (String, PrivateKeySigner) {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        #if canImport(Security)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        #else
        var rng = SystemRandomNumberGenerator()
        for i in 0..<32 { keyBytes[i] = UInt8.random(in: 0...255, using: &rng) }
        #endif
        let hexKey = "0x" + keyBytes.map { String(format: "%02x", $0) }.joined()
        let signer = try PrivateKeySigner(privateKey: hexKey)
        return (hexKey, signer)
    }

    private func skipUnlessAcceptance(file: StaticString = #file, line: UInt = #line) throws {
        guard ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] != nil else {
            throw XCTSkip("ACCEPTANCE_API_URL not set")
        }
        guard Self.agentWallet != nil else {
            throw XCTSkip("Setup failed — wallets not initialized")
        }
    }

    static func getUsdcBalance(_ address: String) async throws -> Double {
        let hex = address.lowercased().replacingOccurrences(of: "0x", with: "")
        let padded = String(repeating: "0", count: 64 - hex.count) + hex
        let callData = "0x70a08231" + padded

        let body = """
        {"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"\(contracts.usdc)","data":"\(callData)"},"latest"]}
        """

        var request = URLRequest(url: URL(string: rpcURL)!)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let resultHex = (json["result"] as? String ?? "0x0").replacingOccurrences(of: "0x", with: "")
        let raw = UInt64(resultHex, radix: 16) ?? 0
        return Double(raw) / 1_000_000.0
    }

    static func waitForBalanceChange(_ address: String, before: Double, timeout: TimeInterval = 30) async throws -> Double {
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
        let tolerance = max(abs(expected) * 0.02, 0.02)
        XCTAssertTrue(abs(actual - expected) <= tolerance,
                      "\(label): expected delta \(expected), got \(actual) (before=\(before), after=\(after))",
                      file: file, line: line)
    }

    func logTx(_ flow: String, _ step: String, txHash: String?) {
        guard let hash = txHash else { return }
        print("[ACCEPTANCE] \(flow) | \(step) | tx=\(hash) | https://sepolia.basescan.org/tx/\(hash)")
    }

    // MARK: - Flow 1: Direct

    func test01_direct() async throws {
        try skipUnlessAcceptance()

        let agent = Self.agentWallet!
        let provider = Self.providerWallet!
        let amount = 1.0

        let agentBefore = try await Self.getUsdcBalance(agent.address)
        let providerBefore = try await Self.getUsdcBalance(provider.address)

        let permit = try await agent.signPermit("direct", amount: amount)
        let tx = try await agent.pay(to: provider.address, amount: amount,
                                     memo: "acceptance-direct", permit: permit)

        XCTAssertTrue(tx.txHash?.hasPrefix("0x") == true)
        logTx("direct", "\(amount) USDC \(agent.address)->\(provider.address)", txHash: tx.txHash)

        let agentAfter = try await Self.waitForBalanceChange(agent.address, before: agentBefore)
        let providerAfter = try await Self.getUsdcBalance(provider.address)

        assertBalanceChange("agent", before: agentBefore, after: agentAfter, expected: -amount)
        assertBalanceChange("provider", before: providerBefore, after: providerAfter, expected: amount * 0.99)
    }

    // MARK: - Flow 2: Escrow

    func test02_escrow() async throws {
        try skipUnlessAcceptance()

        let agent = Self.agentWallet!
        let provider = Self.providerWallet!
        let amount = 2.0

        let agentBefore = try await Self.getUsdcBalance(agent.address)
        let providerBefore = try await Self.getUsdcBalance(provider.address)

        let permit = try await agent.signPermit("escrow", amount: amount)
        let escrow = try await agent.createEscrow(recipient: provider.address,
                                                   amount: amount, permit: permit)
        XCTAssertFalse(escrow.id.isEmpty)
        logTx("escrow", "fund \(amount) USDC", txHash: escrow.txHash)

        _ = try await Self.waitForBalanceChange(agent.address, before: agentBefore)

        let claimed = try await provider.claimStart(id: escrow.id)
        logTx("escrow", "claimStart", txHash: claimed.txHash)
        try await Task.sleep(nanoseconds: 5_000_000_000)

        let released = try await agent.releaseEscrow(id: escrow.id)
        logTx("escrow", "release", txHash: released.txHash)

        let providerAfter = try await Self.waitForBalanceChange(provider.address, before: providerBefore)
        let agentAfter = try await Self.getUsdcBalance(agent.address)

        assertBalanceChange("agent", before: agentBefore, after: agentAfter, expected: -amount)
        assertBalanceChange("provider", before: providerBefore, after: providerAfter, expected: amount * 0.99)
    }

    // MARK: - Flow 3: Tab

    func test03_tab() async throws {
        try skipUnlessAcceptance()

        let agent = Self.agentWallet!
        let provider = Self.providerWallet!
        let limit = 5.0
        let chargeAmount = 1.0
        let chargeUnits: UInt64 = UInt64(chargeAmount * 1_000_000)

        let agentBefore = try await Self.getUsdcBalance(agent.address)
        let providerBefore = try await Self.getUsdcBalance(provider.address)

        let tabContract = Self.contracts.tab
        let chainId = UInt64(Self.contracts.chainId)

        let permit = try await agent.signPermit("tab", amount: limit)
        let tab = try await agent.openTab(provider: provider.address,
                                          limitAmount: limit, perUnit: 0.1, permit: permit)
        XCTAssertFalse(tab.id.isEmpty)
        logTx("tab", "open limit=\(limit)", txHash: nil)

        _ = try await Self.waitForBalanceChange(agent.address, before: agentBefore)

        // Charge
        let callCount: UInt32 = 1
        let chargeSig = try RemitWallet.signTabCharge(
            signer: Self.providerSigner, tabContract: tabContract,
            tabId: tab.id, totalCharged: chargeUnits, callCount: callCount,
            chainId: chainId
        )
        let charge = try await provider.chargeTab(
            id: tab.id, amount: chargeAmount, cumulative: chargeAmount,
            callCount: Int(callCount), providerSig: chargeSig
        )
        XCTAssertEqual(charge.tabId, tab.id)
        print("[ACCEPTANCE] tab | charge | tabId=\(tab.id) amount=\(chargeAmount)")

        // Close
        let closeSig = try RemitWallet.signTabCharge(
            signer: Self.providerSigner, tabContract: tabContract,
            tabId: tab.id, totalCharged: chargeUnits, callCount: callCount,
            chainId: chainId
        )
        let closed = try await agent.closeTab(id: tab.id, finalAmount: chargeAmount,
                                              providerSig: closeSig)
        XCTAssertNotEqual(closed.status, .open)
        print("[ACCEPTANCE] tab | close | status=\(closed.status)")

        let providerAfter = try await Self.waitForBalanceChange(provider.address, before: providerBefore)
        let agentAfter = try await Self.getUsdcBalance(agent.address)

        assertBalanceChange("agent", before: agentBefore, after: agentAfter, expected: -chargeAmount)
        assertBalanceChange("provider", before: providerBefore, after: providerAfter, expected: chargeAmount * 0.99)
    }

    // MARK: - Flow 4: Stream

    func test04_stream() async throws {
        try skipUnlessAcceptance()

        let agent = Self.agentWallet!
        let provider = Self.providerWallet!
        let rate = 0.1  // $0.10/s
        let maxTotal = 2.0

        let agentBefore = try await Self.getUsdcBalance(agent.address)
        let providerBefore = try await Self.getUsdcBalance(provider.address)

        let permit = try await agent.signPermit("stream", amount: maxTotal)
        let stream = try await agent.startStream(payee: provider.address,
                                                 ratePerSecond: rate, maxTotal: maxTotal, permit: permit)
        XCTAssertFalse(stream.id.isEmpty)
        logTx("stream", "open rate=\(rate)/s max=\(maxTotal)", txHash: nil)

        _ = try await Self.waitForBalanceChange(agent.address, before: agentBefore)
        try await Task.sleep(nanoseconds: 5_000_000_000)

        let closed = try await agent.closeStream(id: stream.id)
        XCTAssertEqual(closed.status, .closed)
        print("[ACCEPTANCE] stream | close | status=\(closed.status)")

        let providerAfter = try await Self.waitForBalanceChange(provider.address, before: providerBefore)
        let agentAfter = try await Self.getUsdcBalance(agent.address)

        let agentLoss = agentBefore - agentAfter
        XCTAssertTrue(agentLoss > 0.05, "agent should lose money, loss=\(agentLoss)")
        XCTAssertTrue(agentLoss <= maxTotal + 0.01)

        let providerGain = providerAfter - providerBefore
        XCTAssertTrue(providerGain > 0.04, "provider should gain, gain=\(providerGain)")
    }

    // MARK: - Flow 5: Bounty

    func test05_bounty() async throws {
        try skipUnlessAcceptance()

        let agent = Self.agentWallet!
        let provider = Self.providerWallet!
        let amount = 2.0
        let deadlineTs = Int(Date().timeIntervalSince1970) + 3600

        let agentBefore = try await Self.getUsdcBalance(agent.address)
        let providerBefore = try await Self.getUsdcBalance(provider.address)

        let permit = try await agent.signPermit("bounty", amount: amount)
        let bounty = try await agent.postBounty(amount: amount,
                                                taskDescription: "acceptance-bounty",
                                                deadline: deadlineTs, permit: permit)
        XCTAssertFalse(bounty.id.isEmpty)
        logTx("bounty", "post \(amount) USDC", txHash: nil)

        _ = try await Self.waitForBalanceChange(agent.address, before: agentBefore)

        // Submit evidence
        let evidence = "0x" + String(repeating: "ab", count: 32)
        let sub = try await provider.submitBounty(id: bounty.id, evidenceUri: evidence)
        XCTAssertEqual(sub.bountyId, bounty.id)
        print("[ACCEPTANCE] bounty | submit | id=\(bounty.id)")

        // Retry award up to 15 times (Ponder indexer lag)
        var awarded: Bounty?
        for attempt in 0..<15 {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            do {
                awarded = try await agent.awardBounty(id: bounty.id, submissionId: sub.id)
                break
            } catch {
                if attempt < 14 {
                    print("[ACCEPTANCE] bounty award retry \(attempt + 1): \(error)")
                } else {
                    throw error
                }
            }
        }
        XCTAssertNotNil(awarded)
        XCTAssertEqual(awarded!.status, .awarded)
        print("[ACCEPTANCE] bounty | award | status=\(awarded!.status)")

        let providerAfter = try await Self.waitForBalanceChange(provider.address, before: providerBefore)
        let agentAfter = try await Self.getUsdcBalance(agent.address)

        assertBalanceChange("agent", before: agentBefore, after: agentAfter, expected: -amount)
        assertBalanceChange("provider", before: providerBefore, after: providerAfter, expected: amount * 0.99)
    }

    // MARK: - Flow 6: Deposit

    func test06_deposit() async throws {
        try skipUnlessAcceptance()

        let agent = Self.agentWallet!
        let provider = Self.providerWallet!
        let amount = 2.0

        let agentBefore = try await Self.getUsdcBalance(agent.address)

        let permit = try await agent.signPermit("deposit", amount: amount)
        let deposit = try await agent.placeDeposit(provider: provider.address,
                                                    amount: amount, expiresIn: 3600, permit: permit)
        XCTAssertFalse(deposit.id.isEmpty)
        logTx("deposit", "place \(amount) USDC", txHash: nil)

        let agentMid = try await Self.waitForBalanceChange(agent.address, before: agentBefore)
        assertBalanceChange("agent locked", before: agentBefore, after: agentMid, expected: -amount)

        let returned = try await provider.returnDeposit(id: deposit.id)
        logTx("deposit", "return", txHash: returned.txHash)

        let agentAfter = try await Self.waitForBalanceChange(agent.address, before: agentMid)
        assertBalanceChange("agent refund", before: agentBefore, after: agentAfter, expected: 0)
    }

    // MARK: - Flow 7: x402 (via /x402/prepare)

    func test07_x402_prepare() async throws {
        try skipUnlessAcceptance()

        let agent = Self.agentWallet!
        let contracts = Self.contracts!

        let paymentRequired: [String: Any] = [
            "scheme": "exact",
            "network": "eip155:84532",
            "amount": "100000",
            "asset": contracts.usdc,
            "payTo": contracts.router,
            "maxTimeoutSeconds": 60,
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: paymentRequired)
        let encoded = payloadData.base64EncodedString()

        // POST /x402/prepare via raw URLRequest with auth
        let prepareUrl = URL(string: "\(Self.apiURL)/api/v1/x402/prepare")!
        let reqBody: [String: Any] = [
            "payment_required": encoded,
            "payer": agent.address,
        ]
        var request = URLRequest(url: prepareUrl)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: reqBody)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, resp) = try await URLSession.shared.data(for: request)
        let httpResp = resp as! HTTPURLResponse
        XCTAssertEqual(httpResp.statusCode, 200, "x402/prepare should return 200, got \(httpResp.statusCode)")

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hash = json["hash"] as? String ?? ""
        XCTAssertTrue(hash.hasPrefix("0x"), "hash should be 0x-prefixed")
        XCTAssertEqual(hash.count, 66, "hash should be 66 chars (0x + 64 hex)")
        XCTAssertNotNil(json["from"], "response should have 'from'")
        XCTAssertNotNil(json["to"], "response should have 'to'")
        XCTAssertNotNil(json["value"], "response should have 'value'")

        print("[ACCEPTANCE] x402 | prepare | hash=\(hash.prefix(18))... | from=\((json["from"] as? String ?? "").prefix(10))...")
    }

    // MARK: - Flow 8: AP2 Discovery

    func test08_ap2_discovery() async throws {
        try skipUnlessAcceptance()

        let baseURL = URL(string: Self.apiURL)!
        let card = try await AgentCard.discover(baseURL: baseURL)

        XCTAssertFalse(card.name.isEmpty, "agent card should have a name")
        XCTAssertFalse(card.url.isEmpty, "agent card should have a URL")
        XCTAssertTrue(card.skills.count > 0, "agent card should have skills")

        print("[ACCEPTANCE] ap2-discovery | name=\(card.name) | skills=\(card.skills.count) | x402=true")
    }

    // MARK: - Flow 9: AP2 Payment

    func test09_ap2_payment() async throws {
        try skipUnlessAcceptance()

        let agent = Self.agentWallet!
        let provider = Self.providerWallet!
        let amount = 1.0

        let agentBefore = try await Self.getUsdcBalance(agent.address)
        let providerBefore = try await Self.getUsdcBalance(provider.address)

        let baseURL = URL(string: Self.apiURL)!
        let card = try await AgentCard.discover(baseURL: baseURL)

        let a2a = A2AClient.fromCard(card, signer: Self.agentSigner, chain: "base-sepolia",
                                     verifyingContract: Self.contracts.router)

        let permit = try await agent.signPermit("direct", amount: amount)
        _ = permit  // Permit is pre-signed but A2A uses its own auth

        let task = try await a2a.send(A2ASendOptions(
            to: provider.address, amount: amount, memo: "acceptance-ap2"
        ))

        XCTAssertEqual(task.status.state, "completed", "A2A task should complete, got state=\(task.status.state)")
        let txHash = task.getTxHash()
        XCTAssertNotNil(txHash, "A2A task should produce a txHash")
        XCTAssertTrue(txHash?.hasPrefix("0x") == true)
        logTx("ap2-payment", "\(amount) USDC via A2A", txHash: txHash)

        let agentAfter = try await Self.waitForBalanceChange(agent.address, before: agentBefore)
        let providerAfter = try await Self.getUsdcBalance(provider.address)

        assertBalanceChange("agent", before: agentBefore, after: agentAfter, expected: -amount)
        assertBalanceChange("provider", before: providerBefore, after: providerAfter, expected: amount * 0.99)
    }
}
