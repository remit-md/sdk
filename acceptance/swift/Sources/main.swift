// Swift SDK Acceptance — 9 flows against Base Sepolia.
//
// Flows: Direct, Escrow, Tab (2 charges), Stream, Bounty, Deposit, x402 Weather,
// AP2 Discovery, AP2 Payment.
//
// Usage:
//     ACCEPTANCE_API_URL=https://testnet.remit.md swift run AcceptanceFlows

import Foundation
import RemitMd
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Dispatch)
import Dispatch
#endif

// MARK: - Config

let API_URL = ProcessInfo.processInfo.environment["ACCEPTANCE_API_URL"] ?? "https://testnet.remit.md"
let API_BASE = "\(API_URL)/api/v1"
let RPC_URL = ProcessInfo.processInfo.environment["ACCEPTANCE_RPC_URL"] ?? "https://sepolia.base.org"
let CHAIN_ID: UInt64 = 84532
let USDC_ADDRESS = "0x2d846325766921935f37d5b4478196d3ef93707c"
let FEE_WALLET = "0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38"

// MARK: - Colors

let GREEN = "\u{001B}[0;32m"
let RED = "\u{001B}[0;31m"
let CYAN = "\u{001B}[0;36m"
let YELLOW = "\u{001B}[1;33m"
let BOLD = "\u{001B}[1m"
let RESET = "\u{001B}[0m"

// MARK: - Results

var results: [String: String] = [:]

func logPass(_ flow: String, _ msg: String = "") {
    let extra = msg.isEmpty ? "" : " -- \(msg)"
    print("\(GREEN)[PASS]\(RESET) \(flow)\(extra)")
    results[flow] = "PASS"
}

func logFail(_ flow: String, _ msg: String) {
    print("\(RED)[FAIL]\(RESET) \(flow) -- \(msg)")
    results[flow] = "FAIL"
}

func logInfo(_ msg: String) {
    print("\(CYAN)[INFO]\(RESET) \(msg)")
}

func logTx(_ flow: String, _ step: String, _ txHash: String) {
    print("  [TX] \(flow) | \(step) | https://sepolia.basescan.org/tx/\(txHash)")
}

// MARK: - Helpers

func randomPrivateKey() -> String {
    var keyBytes = [UInt8](repeating: 0, count: 32)
    #if canImport(Security)
    _ = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
    #else
    var rng = SystemRandomNumberGenerator()
    for i in 0..<32 { keyBytes[i] = UInt8.random(in: 0...255, using: &rng) }
    #endif
    return "0x" + keyBytes.map { String(format: "%02x", $0) }.joined()
}

func hexFromBytes(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func bytesFromHex(_ hex: String) -> [UInt8] {
    let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
    var result: [UInt8] = []
    var index = clean.startIndex
    while index < clean.endIndex {
        let next = clean.index(index, offsetBy: 2)
        if let byte = UInt8(clean[index..<next], radix: 16) {
            result.append(byte)
        }
        index = next
    }
    return result
}

var contractsCache: [String: Any]?

func fetchContracts() async throws -> [String: Any] {
    if let cached = contractsCache { return cached }
    let url = URL(string: "\(API_BASE)/contracts")!
    let (data, resp) = try await URLSession.shared.data(from: url)
    let http = resp as! HTTPURLResponse
    guard http.statusCode == 200 else {
        throw NSError(domain: "acceptance", code: http.statusCode,
                      userInfo: [NSLocalizedDescriptionKey: "GET /contracts: \(http.statusCode)"])
    }
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    contractsCache = json
    return json
}

struct TestWallet {
    let wallet: RemitWallet
    let signer: PrivateKeySigner
}

func createTestWallet() async throws -> TestWallet {
    let key = randomPrivateKey()
    let contracts = try await fetchContracts()
    let routerAddress = contracts["router"] as? String ?? ""
    let signer = try PrivateKeySigner(privateKey: key)
    let wallet = try RemitWallet(privateKey: key, chain: .baseSepolia,
                                  baseURL: API_URL, routerAddress: routerAddress)
    return TestWallet(wallet: wallet, signer: signer)
}

func getUsdcBalance(_ address: String) async throws -> Double {
    let hex = address.lowercased().replacingOccurrences(of: "0x", with: "")
    let padded = String(repeating: "0", count: 64 - hex.count) + hex
    let callData = "0x70a08231" + padded

    let body = """
    {"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"\(USDC_ADDRESS)","data":"\(callData)"},"latest"]}
    """
    var request = URLRequest(url: URL(string: RPC_URL)!)
    request.httpMethod = "POST"
    request.httpBody = body.data(using: .utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let (data, _) = try await URLSession.shared.data(for: request)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let resultHex = (json["result"] as? String ?? "0x0").replacingOccurrences(of: "0x", with: "")
    let raw = UInt64(resultHex, radix: 16) ?? 0
    return Double(raw) / 1_000_000.0
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

func fundWallet(_ tw: TestWallet, amount: Double = 100) async throws {
    _ = try await tw.wallet.mint(amount: amount)
    _ = try await waitForBalanceChange(tw.wallet.address, before: 0)
}

// MARK: - EIP-2612 Permit Signing

func signUsdcPermit(signer: PrivateKeySigner, owner: String, spender: String,
                    value: UInt64, nonce: UInt64, deadline: UInt64) throws -> PermitSignature {
    let domainTypeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".data(using: .utf8)!)
    let nameHash = keccak256("USD Coin".data(using: .utf8)!)
    let versionHash = keccak256("2".data(using: .utf8)!)

    var domainData = Data()
    domainData.append(domainTypeHash)
    domainData.append(nameHash)
    domainData.append(versionHash)
    domainData.append(padUint256(CHAIN_ID))
    domainData.append(padAddress(USDC_ADDRESS))
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
    let sigBytes = bytesFromHex(sigClean)

    let r = "0x" + hexFromBytes(Array(sigBytes[0..<32]))
    let s = "0x" + hexFromBytes(Array(sigBytes[32..<64]))
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
    let bytes = bytesFromHex(hex)
    var data = Data(repeating: 0, count: 32)
    data.replaceSubrange(12..<32, with: bytes)
    return data
}

// MARK: - EIP-712 TabCharge Signing

func signTabCharge(signer: PrivateKeySigner, tabContract: String,
                   tabId: String, totalCharged: UInt64, callCount: UInt32) throws -> String {
    return try RemitWallet.signTabCharge(
        signer: signer, tabContract: tabContract,
        tabId: tabId, totalCharged: totalCharged, callCount: callCount,
        chainId: CHAIN_ID
    )
}

// MARK: - Flow 1: Direct Payment

func flowDirect(agent: TestWallet, provider: TestWallet, permitNonce: inout UInt64) async throws {
    let flow = "1. Direct Payment"
    let contracts = try await fetchContracts()
    let routerAddr = contracts["router"] as! String
    let deadline = UInt64(Date().timeIntervalSince1970) + 3600

    let permit = try signUsdcPermit(signer: agent.signer, owner: agent.wallet.address,
                                     spender: routerAddr, value: 2_000_000, nonce: permitNonce, deadline: deadline)
    permitNonce += 1
    let tx = try await agent.wallet.pay(to: provider.wallet.address, amount: 1.0,
                                         memo: "swift-acceptance-direct", permit: permit)
    guard let txHash = tx.txHash, txHash.hasPrefix("0x") else {
        logFail(flow, "bad tx_hash: \(tx.txHash ?? "nil")")
        return
    }
    logTx(flow, "pay", txHash)
    logPass(flow, "tx=\(String(txHash.prefix(18)))...")
}

// MARK: - Flow 2: Escrow

func flowEscrow(agent: TestWallet, provider: TestWallet, permitNonce: inout UInt64) async throws {
    let flow = "2. Escrow"
    let contracts = try await fetchContracts()
    let escrowAddr = contracts["escrow"] as! String
    let deadline = UInt64(Date().timeIntervalSince1970) + 3600

    let permit = try signUsdcPermit(signer: agent.signer, owner: agent.wallet.address,
                                     spender: escrowAddr, value: 6_000_000, nonce: permitNonce, deadline: deadline)
    permitNonce += 1
    let escrow = try await agent.wallet.createEscrow(recipient: provider.wallet.address,
                                                      amount: 5.0, permit: permit)
    guard !escrow.id.isEmpty else {
        logFail(flow, "escrow should have an id")
        return
    }

    _ = try await waitForBalanceChange(agent.wallet.address, before: await getUsdcBalance(agent.wallet.address))
    try await Task.sleep(nanoseconds: 3_000_000_000)

    _ = try await provider.wallet.claimStart(id: escrow.id)
    try await Task.sleep(nanoseconds: 3_000_000_000)

    _ = try await agent.wallet.releaseEscrow(id: escrow.id)
    logPass(flow, "escrow_id=\(escrow.id)")
}

// MARK: - Flow 3: Metered Tab (2 charges)

func flowTab(agent: TestWallet, provider: TestWallet, permitNonce: inout UInt64) async throws {
    let flow = "3. Metered Tab"
    let contracts = try await fetchContracts()
    let tabAddr = contracts["tab"] as! String
    let deadline = UInt64(Date().timeIntervalSince1970) + 3600

    let permit = try signUsdcPermit(signer: agent.signer, owner: agent.wallet.address,
                                     spender: tabAddr, value: 11_000_000, nonce: permitNonce, deadline: deadline)
    permitNonce += 1
    let tab = try await agent.wallet.openTab(provider: provider.wallet.address,
                                              limitAmount: 10.0, perUnit: 0.10, permit: permit)
    guard !tab.id.isEmpty else {
        logFail(flow, "tab should have an id")
        return
    }

    _ = try await waitForBalanceChange(agent.wallet.address, before: await getUsdcBalance(agent.wallet.address))

    // Charge 1: $2
    let sig1 = try signTabCharge(signer: provider.signer, tabContract: tabAddr,
                                  tabId: tab.id, totalCharged: 2_000_000, callCount: 1)
    _ = try await provider.wallet.chargeTab(id: tab.id, amount: 2.0,
                                             cumulative: 2.0, callCount: 1, providerSig: sig1)

    // Charge 2: $1 more (cumulative $3)
    let sig2 = try signTabCharge(signer: provider.signer, tabContract: tabAddr,
                                  tabId: tab.id, totalCharged: 3_000_000, callCount: 2)
    _ = try await provider.wallet.chargeTab(id: tab.id, amount: 1.0,
                                             cumulative: 3.0, callCount: 2, providerSig: sig2)

    // Close with final state ($3, 2 calls)
    let closeSig = try signTabCharge(signer: provider.signer, tabContract: tabAddr,
                                      tabId: tab.id, totalCharged: 3_000_000, callCount: 2)
    let closed = try await agent.wallet.closeTab(id: tab.id, finalAmount: 3.0, providerSig: closeSig)
    guard closed.status != .open else {
        logFail(flow, "tab should not be open after close, got \(closed.status)")
        return
    }
    logPass(flow, "tab_id=\(tab.id), charged=$3, 2 charges")
}

// MARK: - Flow 4: Stream

func flowStream(agent: TestWallet, provider: TestWallet, permitNonce: inout UInt64) async throws {
    let flow = "4. Stream"
    let contracts = try await fetchContracts()
    let streamAddr = contracts["stream"] as! String
    let deadline = UInt64(Date().timeIntervalSince1970) + 3600

    let permit = try signUsdcPermit(signer: agent.signer, owner: agent.wallet.address,
                                     spender: streamAddr, value: 6_000_000, nonce: permitNonce, deadline: deadline)
    permitNonce += 1
    let stream = try await agent.wallet.startStream(payee: provider.wallet.address,
                                                     ratePerSecond: 0.01, maxTotal: 5.0, permit: permit)
    guard !stream.id.isEmpty else {
        logFail(flow, "stream should have an id")
        return
    }

    _ = try await waitForBalanceChange(agent.wallet.address, before: await getUsdcBalance(agent.wallet.address))

    try await Task.sleep(nanoseconds: 5_000_000_000)

    let closed = try await agent.wallet.closeStream(id: stream.id)
    guard closed.status == .closed else {
        logFail(flow, "expected closed, got \(closed.status)")
        return
    }
    logPass(flow, "stream_id=\(stream.id)")
}

// MARK: - Flow 5: Bounty

func flowBounty(agent: TestWallet, provider: TestWallet, permitNonce: inout UInt64) async throws {
    let flow = "5. Bounty"
    let contracts = try await fetchContracts()
    let bountyAddr = contracts["bounty"] as! String
    let deadline = UInt64(Date().timeIntervalSince1970) + 3600

    let permit = try signUsdcPermit(signer: agent.signer, owner: agent.wallet.address,
                                     spender: bountyAddr, value: 6_000_000, nonce: permitNonce, deadline: deadline)
    permitNonce += 1
    let bountyDeadline = Int(Date().timeIntervalSince1970) + 3600
    let bounty = try await agent.wallet.postBounty(amount: 5.0,
                                                    taskDescription: "swift-acceptance-bounty-test",
                                                    deadline: bountyDeadline, permit: permit)
    guard !bounty.id.isEmpty else {
        logFail(flow, "bounty should have an id")
        return
    }

    _ = try await waitForBalanceChange(agent.wallet.address, before: await getUsdcBalance(agent.wallet.address))

    let evidenceHash = "0x" + String(repeating: "ab", count: 32)
    let submission = try await provider.wallet.submitBounty(id: bounty.id, evidenceUri: evidenceHash)
    try await Task.sleep(nanoseconds: 5_000_000_000)

    let awarded = try await agent.wallet.awardBounty(id: bounty.id, submissionId: submission.id)
    guard awarded.status == .awarded else {
        logFail(flow, "expected awarded, got \(awarded.status)")
        return
    }
    logPass(flow, "bounty_id=\(bounty.id)")
}

// MARK: - Flow 6: Deposit

func flowDeposit(agent: TestWallet, provider: TestWallet, permitNonce: inout UInt64) async throws {
    let flow = "6. Deposit"
    let contracts = try await fetchContracts()
    let depositAddr = contracts["deposit"] as! String
    let deadline = UInt64(Date().timeIntervalSince1970) + 3600

    let permit = try signUsdcPermit(signer: agent.signer, owner: agent.wallet.address,
                                     spender: depositAddr, value: 6_000_000, nonce: permitNonce, deadline: deadline)
    permitNonce += 1
    let deposit = try await agent.wallet.placeDeposit(provider: provider.wallet.address,
                                                       amount: 5.0, expiresIn: 3600, permit: permit)
    guard !deposit.id.isEmpty else {
        logFail(flow, "deposit should have an id")
        return
    }

    _ = try await waitForBalanceChange(agent.wallet.address, before: await getUsdcBalance(agent.wallet.address))

    _ = try await provider.wallet.returnDeposit(id: deposit.id)
    logPass(flow, "deposit_id=\(deposit.id)")
}

// MARK: - Flow 7: x402 Weather

func flowX402Weather(agent: TestWallet) async throws {
    let flow = "7. x402 Weather"

    // Step 1: Hit the paywall
    let demoURL = URL(string: "\(API_BASE)/x402/demo")!
    let (_, initialResp) = try await URLSession.shared.data(from: demoURL)
    let httpResp = initialResp as! HTTPURLResponse
    guard httpResp.statusCode == 402 else {
        logFail(flow, "expected 402, got \(httpResp.statusCode)")
        return
    }

    // Parse X-Payment-* headers
    let scheme = httpResp.value(forHTTPHeaderField: "X-Payment-Scheme") ?? "exact"
    let network = httpResp.value(forHTTPHeaderField: "X-Payment-Network") ?? "eip155:\(CHAIN_ID)"
    let amountStr = httpResp.value(forHTTPHeaderField: "X-Payment-Amount") ?? "5000000"
    let asset = httpResp.value(forHTTPHeaderField: "X-Payment-Asset") ?? USDC_ADDRESS
    let payTo = httpResp.value(forHTTPHeaderField: "X-Payment-PayTo") ?? ""
    let amountRaw = UInt64(amountStr) ?? 5_000_000

    logInfo("  Paywall: \(scheme) | $\(String(format: "%.2f", Double(amountRaw) / 1_000_000.0)) USDC | network=\(network)")

    // Step 2: Sign EIP-3009 TransferWithAuthorization
    let chainComponents = network.split(separator: ":")
    let chainId = chainComponents.count == 2 ? (UInt64(chainComponents[1]) ?? CHAIN_ID) : CHAIN_ID
    let now = UInt64(Date().timeIntervalSince1970)
    let validBefore = now + 300

    var nonceBytes = [UInt8](repeating: 0, count: 32)
    for i in 0..<32 { nonceBytes[i] = UInt8.random(in: 0...255) }
    let nonceHex = "0x" + hexFromBytes(nonceBytes)
    let nonceData = Data(nonceBytes)

    // Build EIP-712 digest for TransferWithAuthorization
    let domainTypeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".data(using: .utf8)!)
    let nameHash = keccak256("USD Coin".data(using: .utf8)!)
    let versionHash = keccak256("2".data(using: .utf8)!)

    var domainData = Data()
    domainData.append(domainTypeHash)
    domainData.append(nameHash)
    domainData.append(versionHash)
    domainData.append(padUint256(chainId))
    domainData.append(padAddress(asset))
    let domainSep = keccak256(domainData)

    let typeHash = keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)".data(using: .utf8)!)

    var structData = Data()
    structData.append(typeHash)
    structData.append(padAddress(agent.wallet.address))
    structData.append(padAddress(payTo))
    structData.append(padUint256(amountRaw))
    structData.append(padUint256(0))
    structData.append(padUint256(validBefore))
    var paddedNonce = Data(repeating: 0, count: 32)
    let bytesToCopy = min(nonceData.count, 32)
    paddedNonce.replaceSubrange(0..<bytesToCopy, with: nonceData.prefix(bytesToCopy))
    structData.append(paddedNonce)
    let structHash = keccak256(structData)

    var finalDigest = Data([0x19, 0x01])
    finalDigest.append(domainSep)
    finalDigest.append(structHash)
    let digest = keccak256(finalDigest)

    let signature = try agent.signer.sign(digest: digest)

    // Step 3: Settle on-chain via POST /x402/settle
    let settlePayload: [String: Any] = [
        "paymentPayload": [
            "scheme": scheme,
            "network": network,
            "x402Version": 1,
            "payload": [
                "signature": signature,
                "authorization": [
                    "from": agent.wallet.address,
                    "to": payTo,
                    "value": amountStr,
                    "validAfter": "0",
                    "validBefore": String(validBefore),
                    "nonce": nonceHex,
                ] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
        "paymentRequired": [
            "scheme": scheme,
            "network": network,
            "amount": amountStr,
            "asset": asset,
            "payTo": payTo,
            "maxTimeoutSeconds": 300,
        ] as [String: Any],
    ]

    let settleJSON = try JSONSerialization.data(withJSONObject: settlePayload)
    var settleReq = URLRequest(url: URL(string: "\(API_BASE)/x402/settle")!)
    settleReq.httpMethod = "POST"
    settleReq.httpBody = settleJSON
    settleReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

    // Build EIP-712 auth headers for settle endpoint
    let authContracts = try await fetchContracts()
    let authRouterAddr = authContracts["router"] as? String ?? ""
    let authTimestamp = UInt64(Date().timeIntervalSince1970)
    var authNonceBytes = [UInt8](repeating: 0, count: 32)
    for i in 0..<32 { authNonceBytes[i] = UInt8.random(in: 0...255) }
    let authNonceHex = "0x" + hexFromBytes(authNonceBytes)

    // Domain separator: remit.md / 0.1
    let authDomainTypeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".data(using: .utf8)!)
    let authNameHash = keccak256("remit.md".data(using: .utf8)!)
    let authVersionHash = keccak256("0.1".data(using: .utf8)!)
    var authDomainData = Data()
    authDomainData.append(authDomainTypeHash)
    authDomainData.append(authNameHash)
    authDomainData.append(authVersionHash)
    authDomainData.append(padUint256(CHAIN_ID))
    authDomainData.append(padAddress(authRouterAddr))
    let authDomainSep = keccak256(authDomainData)

    // APIRequest struct — string fields are keccak256-hashed in EIP-712
    let authStructTypeHash = keccak256("APIRequest(string method,string path,uint256 timestamp,bytes32 nonce)".data(using: .utf8)!)
    let methodHash = keccak256("POST".data(using: .utf8)!)
    let pathHash = keccak256("/api/v1/x402/settle".data(using: .utf8)!)
    var authStructData = Data()
    authStructData.append(authStructTypeHash)
    authStructData.append(methodHash)
    authStructData.append(pathHash)
    authStructData.append(padUint256(authTimestamp))
    authStructData.append(Data(authNonceBytes))
    let authStructHash = keccak256(authStructData)

    var authFinalData = Data([0x19, 0x01])
    authFinalData.append(authDomainSep)
    authFinalData.append(authStructHash)
    let authDigest = keccak256(authFinalData)
    let authSig = try agent.signer.sign(digest: authDigest)

    settleReq.setValue(authSig, forHTTPHeaderField: "X-Remit-Signature")
    settleReq.setValue(agent.wallet.address, forHTTPHeaderField: "X-Remit-Agent")
    settleReq.setValue(String(authTimestamp), forHTTPHeaderField: "X-Remit-Timestamp")
    settleReq.setValue(authNonceHex, forHTTPHeaderField: "X-Remit-Nonce")

    let (settleData, settleResp) = try await URLSession.shared.data(for: settleReq)
    let settleHttp = settleResp as! HTTPURLResponse
    guard settleHttp.statusCode == 200 else {
        let body = String(data: settleData, encoding: .utf8) ?? "?"
        logFail(flow, "settle returned \(settleHttp.statusCode): \(body)")
        return
    }

    let settleResult = try JSONSerialization.jsonObject(with: settleData) as? [String: Any] ?? [:]
    let txHash = settleResult["transactionHash"] as? String ?? ""
    guard !txHash.isEmpty else {
        logFail(flow, "settle returned no tx_hash: \(settleResult)")
        return
    }
    logTx(flow, "settle", txHash)

    // Step 4: Fetch weather data with payment proof
    var weatherReq = URLRequest(url: demoURL)
    weatherReq.setValue(txHash, forHTTPHeaderField: "X-Payment-Response")
    let (weatherData, weatherResp) = try await URLSession.shared.data(for: weatherReq)
    let weatherHttp = weatherResp as! HTTPURLResponse
    guard weatherHttp.statusCode == 200 else {
        logFail(flow, "weather fetch returned \(weatherHttp.statusCode)")
        return
    }

    let weather = try JSONSerialization.jsonObject(with: weatherData) as? [String: Any] ?? [:]

    // Display weather report
    let loc = weather["location"] as? [String: Any] ?? [:]
    let cur = weather["current"] as? [String: Any] ?? [:]
    let cond = cur["condition"] as? [String: Any] ?? [:]

    let city = loc["name"] as? String ?? "Unknown"
    let region = "\(loc["region"] as? String ?? ""), \(loc["country"] as? String ?? "")"
    let tempF = cur["temp_f"] ?? "?"
    let tempC = cur["temp_c"] ?? "?"
    let condition = cond["text"] as? String ?? (cur["condition"] as? String ?? "Unknown")
    let humidity = cur["humidity"] ?? "?"
    let windMph = cur["wind_mph"] ?? cur["wind_kph"] ?? "?"
    let windDir = cur["wind_dir"] as? String ?? ""

    print()
    print("\(CYAN)+---------------------------------------------+\(RESET)")
    print("\(CYAN)|\(RESET)  \(BOLD)x402 Weather Report\(RESET) (paid $\(String(format: "%.2f", Double(amountRaw) / 1_000_000.0)) USDC)   \(CYAN)|\(RESET)")
    print("\(CYAN)+---------------------------------------------+\(RESET)")
    print("\(CYAN)|\(RESET)  City:        \(city)\(CYAN)|\(RESET)")
    print("\(CYAN)|\(RESET)  Region:      \(region)\(CYAN)|\(RESET)")
    print("\(CYAN)|\(RESET)  Temperature: \(tempF)F / \(tempC)C\(CYAN)|\(RESET)")
    print("\(CYAN)|\(RESET)  Condition:   \(condition)\(CYAN)|\(RESET)")
    print("\(CYAN)|\(RESET)  Humidity:    \(humidity)%\(CYAN)|\(RESET)")
    print("\(CYAN)|\(RESET)  Wind:        \(windMph) mph \(windDir)\(CYAN)|\(RESET)")
    print("\(CYAN)+---------------------------------------------+\(RESET)")
    print()

    logPass(flow, "city=\(city), tx=\(String(txHash.prefix(18)))...")
}

// MARK: - Flow 8: AP2 Discovery

func flowAP2Discovery() async throws {
    let flow = "8. AP2 Discovery"
    let card = try await AgentCard.discover(baseURL: URL(string: API_URL)!)

    print()
    print("\(CYAN)+---------------------------------------------+\(RESET)")
    print("\(CYAN)|\(RESET)  \(BOLD)A2A Agent Card\(RESET)                            \(CYAN)|\(RESET)")
    print("\(CYAN)+---------------------------------------------+\(RESET)")
    print("\(CYAN)|\(RESET)  Name:     \(card.name)\(CYAN)|\(RESET)")
    print("\(CYAN)|\(RESET)  Version:  \(card.version)\(CYAN)|\(RESET)")
    print("\(CYAN)|\(RESET)  Protocol: \(card.protocolVersion)\(CYAN)|\(RESET)")
    print("\(CYAN)|\(RESET)  URL:      \(String(card.url.prefix(32)))\(CYAN)|\(RESET)")
    if !card.skills.isEmpty {
        print("\(CYAN)|\(RESET)  Skills:   \(card.skills.count) total\(CYAN)|\(RESET)")
        for s in card.skills.prefix(5) {
            print("\(CYAN)|\(RESET)    - \(String(s.name.prefix(38)))\(CYAN)|\(RESET)")
        }
    }
    let settle = card.x402.settleEndpoint
    print("\(CYAN)|\(RESET)  x402:     settle=\(String(settle.prefix(25)))\(CYAN)|\(RESET)")
    let caps = card.capabilities
    let exts = caps.extensions.isEmpty ? "none" : caps.extensions.map { $0.uri.split(separator: "/").last.map(String.init) ?? $0.uri }.joined(separator: ", ")
    print("\(CYAN)|\(RESET)  Caps:     streaming=\(caps.streaming), exts=\(String(exts.prefix(16)))\(CYAN)|\(RESET)")
    print("\(CYAN)+---------------------------------------------+\(RESET)")
    print()

    guard !card.name.isEmpty else {
        logFail(flow, "agent card should have a name")
        return
    }
    logPass(flow, "name=\(card.name)")
}

// MARK: - Flow 9: AP2 Payment

func flowAP2Payment(agent: TestWallet, provider: TestWallet) async throws {
    let flow = "9. AP2 Payment"
    let card = try await AgentCard.discover(baseURL: URL(string: API_URL)!)

    let mandate = IntentMandate(
        mandateId: hexFromBytes((0..<16).map { _ in UInt8.random(in: 0...255) }),
        expiresAt: "2099-12-31T23:59:59Z",
        issuer: agent.wallet.address,
        allowance: IntentAllowance(maxAmount: "5.00", currency: "USDC")
    )

    let a2a = A2AClient.fromCard(card, signer: agent.signer, chain: "base-sepolia")
    let task = try await a2a.send(A2ASendOptions(
        to: provider.wallet.address,
        amount: 1.0,
        memo: "swift-acceptance-ap2-payment",
        mandate: mandate
    ))

    guard !task.id.isEmpty else {
        print("\u{001B}[1;33m[SKIP]\u{001B}[0m \(flow) -- AP2 task has no ID (endpoint may not be available on testnet)")
        results[flow] = "SKIP"
        return
    }
    guard task.status.state == "completed" else {
        logFail(flow, "a2a task should be completed, got state=\(task.status.state)")
        return
    }

    let txHash = task.getTxHash() ?? ""
    if !txHash.isEmpty {
        logTx(flow, "a2a-pay", txHash)
    }

    // Verify persistence
    let fetched = try await a2a.getTask(taskId: task.id)
    guard fetched.id == task.id else {
        logFail(flow, "fetched task id should match")
        return
    }

    logPass(flow, "task_id=\(task.id), state=\(task.status.state)")
}

// MARK: - Main

func runAllFlows() async {
    print()
    print("\(BOLD)Swift SDK -- 9 Flow Acceptance Suite\(RESET)")
    print("  API: \(API_URL)")
    print("  RPC: \(RPC_URL)")
    print()

    do {
        logInfo("Creating agent wallet...")
        let agent = try await createTestWallet()
        logInfo("  Agent:    \(agent.wallet.address)")

        logInfo("Creating provider wallet...")
        let provider = try await createTestWallet()
        logInfo("  Provider: \(provider.wallet.address)")

        logInfo("Minting $100 USDC to agent...")
        try await fundWallet(agent, amount: 100)
        let bal = try await getUsdcBalance(agent.wallet.address)
        logInfo("  Agent balance: $\(String(format: "%.2f", bal))")

        logInfo("Minting $100 USDC to provider...")
        try await fundWallet(provider, amount: 100)
        let bal2 = try await getUsdcBalance(provider.wallet.address)
        logInfo("  Provider balance: $\(String(format: "%.2f", bal2))")
        print()

        // Permit nonce counter — each permit consumed on-chain increments the nonce
        var permitNonce: UInt64 = 0

        // Run flows sequentially (can't use closures with inout, so call directly)
        let flowEntries: [(String, () async throws -> Void)] = [
            ("7. x402 Weather", { try await flowX402Weather(agent: agent) }),
            ("8. AP2 Discovery", { try await flowAP2Discovery() }),
            ("9. AP2 Payment", { try await flowAP2Payment(agent: agent, provider: provider) }),
        ]

        // Flows 1-6 need permit nonce — call directly
        let permitFlows: [(String, (inout UInt64) async throws -> Void)] = [
            ("1. Direct Payment", { nonce in try await flowDirect(agent: agent, provider: provider, permitNonce: &nonce) }),
            ("2. Escrow", { nonce in try await flowEscrow(agent: agent, provider: provider, permitNonce: &nonce) }),
            ("3. Metered Tab", { nonce in try await flowTab(agent: agent, provider: provider, permitNonce: &nonce) }),
            ("4. Stream", { nonce in try await flowStream(agent: agent, provider: provider, permitNonce: &nonce) }),
            ("5. Bounty", { nonce in try await flowBounty(agent: agent, provider: provider, permitNonce: &nonce) }),
            ("6. Deposit", { nonce in try await flowDeposit(agent: agent, provider: provider, permitNonce: &nonce) }),
        ]

        for (name, fn) in permitFlows {
            do {
                try await fn(&permitNonce)
            } catch {
                logFail(name, "\(type(of: error)): \(error)")
            }
        }

        for (name, fn) in flowEntries {
            do {
                try await fn()
            } catch {
                logFail(name, "\(type(of: error)): \(error)")
            }
        }
    } catch {
        print("\(RED)[FATAL]\(RESET) Setup failed: \(error)")
    }

    // Summary
    let passed = results.values.filter { $0 == "PASS" }.count
    let failed = results.values.filter { $0 == "FAIL" }.count
    let skipped = 9 - passed - failed
    print()
    print("\(BOLD)Swift Summary: \(GREEN)\(passed) passed\(RESET), \(RED)\(failed) failed\(RESET) / 9 flows")

    // JSON summary on last line for run-all.sh to parse
    let summary = "{\"passed\":\(passed),\"failed\":\(failed),\"skipped\":\(skipped)}"
    print(summary)

    if failed > 0 {
        exit(1)
    }
}

// Entry point: top-level async call in main.swift
let semaphore = DispatchSemaphore(value: 0)
Task {
    await runAllFlows()
    semaphore.signal()
}
semaphore.wait()
