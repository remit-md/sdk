import Foundation

/// Main entry point for remit.md payments.
public final class RemitWallet: @unchecked Sendable {
    private let transport: any Transport
    private let signerAddress: String
    private let chainName: String
    private var contractsCache: ContractAddresses?
    private let cacheLock = NSLock()

    public init(privateKey: String, chain: RemitChain = .baseSepolia, baseURL: String? = nil, routerAddress: String? = nil) throws {
        let signer = try PrivateKeySigner(privateKey: privateKey)
        self.transport = HttpTransport(
            baseURL: baseURL ?? chain.baseURL,
            chainId: UInt64(chain.rawValue),
            routerAddress: routerAddress ?? "",
            signer: signer
        )
        self.signerAddress = signer.address
        self.chainName = chain.chainName
    }

    public init(mock: MockRemit) {
        self.transport = MockTransport(mock: mock)
        self.signerAddress = mock.walletAddress
        self.chainName = "base"
    }

    public static func fromEnvironment() throws -> RemitWallet {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["REMITMD_PRIVATE_KEY"] else {
            throw RemitError(RemitError.unauthorized, "REMITMD_PRIVATE_KEY environment variable not set")
        }
        let chainStr = env["REMITMD_CHAIN"] ?? "base-sepolia"
        let chain: RemitChain = chainStr == "base" ? .base : .baseSepolia
        let routerAddress = env["REMITMD_ROUTER_ADDRESS"]
        return try RemitWallet(privateKey: key, chain: chain, routerAddress: routerAddress)
    }

    // MARK: - Contracts

    /// Get deployed contract addresses. Cached for the lifetime of this client instance.
    public func getContracts() async throws -> ContractAddresses {
        cacheLock.lock()
        if let cached = contractsCache {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let contracts: ContractAddresses = try await transport.request(
            method: "GET", path: "/api/v0/contracts", body: Optional<EmptyBody>.none
        )
        cacheLock.lock()
        contractsCache = contracts
        cacheLock.unlock()
        return contracts
    }

    // MARK: - Direct payment

    public func pay(to recipient: String, amount: Double, memo: String? = nil, permit: PermitSignature? = nil) async throws -> Transaction {
        try validateAddress(recipient)
        try validateAmount(amount)
        return try await transport.request(
            method: "POST", path: "/api/v0/payments/direct",
            body: PayBody(to: recipient, amount: amount, memo: memo, permit: permit)
        )
    }

    // MARK: - Escrow

    public func createEscrow(recipient: String, amount: Double, conditions: String? = nil, permit: PermitSignature? = nil) async throws -> Escrow {
        try validateAddress(recipient)
        try validateAmount(amount)

        // Step 1: create invoice on server.
        let invoiceId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).lowercased()
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).lowercased()
        let _: InvoiceResponse = try await transport.request(
            method: "POST", path: "/api/v0/invoices",
            body: InvoiceBody(
                id: String(invoiceId), chain: chainName,
                from_agent: signerAddress.lowercased(), to_agent: recipient.lowercased(),
                amount: String(format: "%.6f", amount), type: "escrow",
                task: conditions ?? "", nonce: String(nonce), signature: "0x"
            )
        )

        // Step 2: fund the escrow.
        return try await transport.request(
            method: "POST", path: "/api/v0/escrows",
            body: EscrowFundBody(invoice_id: String(invoiceId), permit: permit)
        )
    }

    public func claimStart(id: String) async throws -> Escrow {
        return try await transport.request(
            method: "POST", path: "/api/v0/escrows/\(id)/claim-start", body: Optional<EmptyBody>.none
        )
    }

    public func getEscrow(id: String) async throws -> Escrow {
        return try await transport.request(
            method: "GET", path: "/api/v0/escrows/\(id)", body: Optional<EmptyBody>.none
        )
    }

    public func releaseEscrow(id: String) async throws -> Escrow {
        return try await transport.request(
            method: "POST", path: "/api/v0/escrows/\(id)/release", body: Optional<EmptyBody>.none
        )
    }

    public func cancelEscrow(id: String) async throws -> Escrow {
        return try await transport.request(
            method: "POST", path: "/api/v0/escrows/\(id)/cancel", body: Optional<EmptyBody>.none
        )
    }

    // MARK: - Metered tabs

    public func openTab(recipient: String, limit: Double, permit: PermitSignature? = nil) async throws -> Tab {
        try validateAddress(recipient)
        try validateAmount(limit)
        return try await transport.request(
            method: "POST", path: "/api/v0/tabs",
            body: TabBody(chain: chainName, recipient: recipient, limit: limit, permit: permit)
        )
    }

    public func debitTab(id: String, amount: Double, memo: String? = nil) async throws -> TabDebit {
        try validateAmount(amount)
        return try await transport.request(
            method: "POST", path: "/api/v0/tabs/\(id)/charge",
            body: DebitBody(amount: amount, memo: memo)
        )
    }

    public func closeTab(id: String) async throws -> Tab {
        return try await transport.request(
            method: "POST", path: "/api/v0/tabs/\(id)/close", body: Optional<EmptyBody>.none
        )
    }

    // MARK: - Streaming

    public func startStream(recipient: String, ratePerSecond: Double, permit: PermitSignature? = nil) async throws -> Stream {
        try validateAddress(recipient)
        guard ratePerSecond > 0 else {
            throw RemitError(RemitError.invalidAmount, "ratePerSecond must be positive")
        }
        return try await transport.request(
            method: "POST", path: "/api/v0/streams",
            body: StreamBody(chain: chainName, recipient: recipient, ratePerSecond: ratePerSecond, permit: permit)
        )
    }

    public func closeStream(id: String) async throws -> Stream {
        return try await transport.request(
            method: "POST", path: "/api/v0/streams/\(id)/close", body: Optional<EmptyBody>.none
        )
    }

    // MARK: - Bounties

    public func postBounty(amount: Double, description: String, permit: PermitSignature? = nil) async throws -> Bounty {
        try validateAmount(amount)
        guard !description.isEmpty else {
            throw RemitError(RemitError.serverError, "bounty description must not be empty")
        }
        return try await transport.request(
            method: "POST", path: "/api/v0/bounties",
            body: BountyBody(chain: chainName, amount: amount, description: description, permit: permit)
        )
    }

    public func awardBounty(id: String, winner: String) async throws -> Bounty {
        try validateAddress(winner)
        return try await transport.request(
            method: "POST", path: "/api/v0/bounties/\(id)/award",
            body: AwardBody(winner: winner)
        )
    }

    public func listBounties(
        status: String? = "open",
        poster: String? = nil,
        submitter: String? = nil,
        limit: Int = 20
    ) async throws -> [Bounty] {
        var params: [String] = ["limit=\(limit)"]
        if let s = status { params.append("status=\(s)") }
        if let p = poster { params.append("poster=\(p)") }
        if let s = submitter { params.append("submitter=\(s)") }
        let qs = params.joined(separator: "&")
        let resp: BountyListResponse = try await transport.request(
            method: "GET", path: "/api/v0/bounties?\(qs)",
            body: Optional<EmptyBody>.none
        )
        return resp.data
    }

    // MARK: - Deposits

    public func lockDeposit(recipient: String, amount: Double, reason: String? = nil, permit: PermitSignature? = nil) async throws -> Deposit {
        try validateAddress(recipient)
        try validateAmount(amount)
        return try await transport.request(
            method: "POST", path: "/api/v0/deposits",
            body: DepositBody(recipient: recipient, amount: amount, reason: reason, permit: permit)
        )
    }

    // MARK: - Intent

    public func expressIntent(to recipient: String, amount: Double, model: String = "direct") async throws -> Intent {
        try validateAddress(recipient)
        try validateAmount(amount)
        return try await transport.request(
            method: "POST", path: "/api/v0/intent",
            body: IntentBody(to: recipient, amount: amount, model: model)
        )
    }

    // MARK: - Analytics

    public func balance(of address: String? = nil) async throws -> Balance {
        let addr = address ?? signerAddress
        return try await transport.request(
            method: "GET", path: "/api/v0/balance/\(addr)", body: Optional<EmptyBody>.none
        )
    }

    public func reputation(of address: String? = nil) async throws -> Reputation {
        let addr = address ?? signerAddress
        return try await transport.request(
            method: "GET", path: "/api/v0/reputation/\(addr)", body: Optional<EmptyBody>.none
        )
    }

    public func spendingSummary(of address: String? = nil) async throws -> SpendingSummary {
        let addr = address ?? signerAddress
        return try await transport.request(
            method: "GET", path: "/api/v0/spending/\(addr)", body: Optional<EmptyBody>.none
        )
    }

    public func history(of address: String? = nil) async throws -> TransactionList {
        let addr = address ?? signerAddress
        return try await transport.request(
            method: "GET", path: "/api/v0/history/\(addr)", body: Optional<EmptyBody>.none
        )
    }

    public func budget(of address: String? = nil) async throws -> Budget {
        let addr = address ?? signerAddress
        return try await transport.request(
            method: "GET", path: "/api/v0/budget/\(addr)", body: Optional<EmptyBody>.none
        )
    }

    // MARK: - Validation

    private func validateAddress(_ address: String) throws {
        guard address.hasPrefix("0x"), address.count == 42,
              address.dropFirst(2).allSatisfy({ $0.isHexDigit }) else {
            throw RemitError.invalidAddress(address)
        }
    }

    // MARK: - Webhooks

    /// Registers a webhook endpoint to receive event notifications.
    /// - Parameters:
    ///   - url: The HTTPS endpoint that will receive POST notifications.
    ///   - events: Event types to subscribe to (e.g. ["payment.sent", "escrow.funded"]).
    ///   - chains: Optional chain names to filter by. Pass nil for all chains.
    public func registerWebhook(url: String, events: [String], chains: [String]? = nil) async throws -> Webhook {
        return try await transport.request(
            method: "POST", path: "/api/v0/webhooks",
            body: WebhookBody(url: url, events: events, chains: chains)
        )
    }

    // MARK: - One-time operator links

    public func createFundLink() async throws -> LinkResponse {
        return try await transport.request(
            method: "POST", path: "/api/v0/links/fund", body: Optional<EmptyBody>.none
        )
    }

    public func createWithdrawLink() async throws -> LinkResponse {
        return try await transport.request(
            method: "POST", path: "/api/v0/links/withdraw", body: Optional<EmptyBody>.none
        )
    }

    // MARK: - Testnet

    /// Mint testnet USDC via POST /mint. Max $2,500 per call, once per hour per wallet.
    public func mint(amount: Double) async throws -> MintResponse {
        return try await transport.request(
            method: "POST", path: "/api/v0/mint",
            body: MintBody(wallet: signerAddress, amount: amount)
        )
    }

    private func validateAmount(_ amount: Double) throws {
        guard amount > 0 else {
            throw RemitError.invalidAmount(amount, reason: "amount must be positive")
        }
        guard amount <= 1_000_000 else {
            throw RemitError.invalidAmount(amount, reason: "amount exceeds per-transaction limit of 1,000,000 USDC")
        }
    }
}

// MARK: - Request body structs (private)

private struct EmptyBody: Codable {}
private struct PayBody: Codable { let to: String; let amount: Double; let memo: String?; let permit: PermitSignature? }
private struct InvoiceBody: Codable { let id: String; let chain: String; let from_agent: String; let to_agent: String; let amount: String; let type: String; let task: String; let nonce: String; let signature: String }
private struct InvoiceResponse: Codable { let id: String? }
private struct EscrowFundBody: Codable { let invoice_id: String; let permit: PermitSignature? }
private struct TabBody: Codable { let chain: String; let recipient: String; let limit: Double; let permit: PermitSignature? }
private struct DebitBody: Codable { let amount: Double; let memo: String? }
private struct StreamBody: Codable {
    let chain: String; let recipient: String; let ratePerSecond: Double; let permit: PermitSignature?
    enum CodingKeys: String, CodingKey {
        case chain, recipient, permit
        case ratePerSecond = "rate_per_second"
    }
}
private struct BountyBody: Codable { let chain: String; let amount: Double; let description: String; let permit: PermitSignature? }
private struct BountyListResponse: Codable { let data: [Bounty] }
private struct AwardBody: Codable { let winner: String }
private struct DepositBody: Codable { let recipient: String; let amount: Double; let reason: String?; let permit: PermitSignature? }
private struct IntentBody: Codable { let to: String; let amount: Double; let model: String }
private struct WebhookBody: Codable { let url: String; let events: [String]; let chains: [String]? }
private struct MintBody: Codable { let wallet: String; let amount: Double }

/// Response from POST /mint.
public struct MintResponse: Codable, Sendable {
    public let txHash: String
    public let balance: Double

    enum CodingKeys: String, CodingKey {
        case txHash = "tx_hash"
        case balance
    }
}
