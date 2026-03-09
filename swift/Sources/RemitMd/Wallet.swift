import Foundation

/// Main entry point for remit.md payments.
public final class RemitWallet: Sendable {
    private let transport: any Transport
    private let signerAddress: String

    public init(privateKey: String, chain: RemitChain = .baseSepolia, baseURL: String? = nil) throws {
        let signer = try PrivateKeySigner(privateKey: privateKey)
        self.transport = HttpTransport(baseURL: baseURL ?? chain.baseURL, signer: signer)
        self.signerAddress = signer.address
    }

    public init(mock: MockRemit) {
        self.transport = MockTransport(mock: mock)
        self.signerAddress = mock.walletAddress
    }

    public static func fromEnvironment() throws -> RemitWallet {
        guard let key = ProcessInfo.processInfo.environment["REMIT_PRIVATE_KEY"] else {
            throw RemitError(RemitError.unauthorized, "REMIT_PRIVATE_KEY environment variable not set")
        }
        let chainStr = ProcessInfo.processInfo.environment["REMIT_CHAIN"] ?? "base-sepolia"
        let chain: RemitChain = chainStr == "base" ? .base
            : chainStr == "arbitrum" ? .arbitrum
            : chainStr == "optimism" ? .optimism
            : .baseSepolia
        return try RemitWallet(privateKey: key, chain: chain)
    }

    // MARK: - Direct payment

    public func pay(to recipient: String, amount: Double, memo: String? = nil) async throws -> Transaction {
        try validateAddress(recipient)
        try validateAmount(amount)
        return try await transport.request(
            method: "POST", path: "/api/v0/pay",
            body: PayBody(to: recipient, amount: amount, memo: memo)
        )
    }

    // MARK: - Escrow

    public func createEscrow(recipient: String, amount: Double, conditions: String? = nil) async throws -> Escrow {
        try validateAddress(recipient)
        try validateAmount(amount)
        return try await transport.request(
            method: "POST", path: "/api/v0/escrow",
            body: EscrowBody(recipient: recipient, amount: amount, conditions: conditions)
        )
    }

    public func getEscrow(id: String) async throws -> Escrow {
        return try await transport.request(
            method: "GET", path: "/api/v0/escrow/\(id)", body: Optional<EmptyBody>.none
        )
    }

    public func releaseEscrow(id: String) async throws -> Escrow {
        return try await transport.request(
            method: "POST", path: "/api/v0/escrow/\(id)/release", body: Optional<EmptyBody>.none
        )
    }

    public func cancelEscrow(id: String) async throws -> Escrow {
        return try await transport.request(
            method: "POST", path: "/api/v0/escrow/\(id)/cancel", body: Optional<EmptyBody>.none
        )
    }

    // MARK: - Metered tabs

    public func openTab(recipient: String, limit: Double) async throws -> Tab {
        try validateAddress(recipient)
        try validateAmount(limit)
        return try await transport.request(
            method: "POST", path: "/api/v0/tab",
            body: TabBody(recipient: recipient, limit: limit)
        )
    }

    public func debitTab(id: String, amount: Double, memo: String? = nil) async throws -> TabDebit {
        try validateAmount(amount)
        return try await transport.request(
            method: "POST", path: "/api/v0/tab/\(id)/debit",
            body: DebitBody(amount: amount, memo: memo)
        )
    }

    public func closeTab(id: String) async throws -> Tab {
        return try await transport.request(
            method: "POST", path: "/api/v0/tab/\(id)/close", body: Optional<EmptyBody>.none
        )
    }

    // MARK: - Streaming

    public func startStream(recipient: String, ratePerSecond: Double) async throws -> Stream {
        try validateAddress(recipient)
        guard ratePerSecond > 0 else {
            throw RemitError(RemitError.invalidAmount, "ratePerSecond must be positive")
        }
        return try await transport.request(
            method: "POST", path: "/api/v0/stream",
            body: StreamBody(recipient: recipient, ratePerSecond: ratePerSecond)
        )
    }

    public func stopStream(id: String) async throws -> Stream {
        return try await transport.request(
            method: "POST", path: "/api/v0/stream/\(id)/stop", body: Optional<EmptyBody>.none
        )
    }

    // MARK: - Bounties

    public func postBounty(amount: Double, description: String) async throws -> Bounty {
        try validateAmount(amount)
        guard !description.isEmpty else {
            throw RemitError(RemitError.serverError, "bounty description must not be empty")
        }
        return try await transport.request(
            method: "POST", path: "/api/v0/bounty",
            body: BountyBody(amount: amount, description: description)
        )
    }

    public func awardBounty(id: String, winner: String) async throws -> Bounty {
        try validateAddress(winner)
        return try await transport.request(
            method: "POST", path: "/api/v0/bounty/\(id)/award",
            body: AwardBody(winner: winner)
        )
    }

    // MARK: - Deposits

    public func lockDeposit(recipient: String, amount: Double, reason: String? = nil) async throws -> Deposit {
        try validateAddress(recipient)
        try validateAmount(amount)
        return try await transport.request(
            method: "POST", path: "/api/v0/deposit",
            body: DepositBody(recipient: recipient, amount: amount, reason: reason)
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
private struct PayBody: Codable { let to: String; let amount: Double; let memo: String? }
private struct EscrowBody: Codable { let recipient: String; let amount: Double; let conditions: String? }
private struct TabBody: Codable { let recipient: String; let limit: Double }
private struct DebitBody: Codable { let amount: Double; let memo: String? }
private struct StreamBody: Codable {
    let recipient: String; let ratePerSecond: Double
    enum CodingKeys: String, CodingKey {
        case recipient
        case ratePerSecond = "rate_per_second"
    }
}
private struct BountyBody: Codable { let amount: Double; let description: String }
private struct AwardBody: Codable { let winner: String }
private struct DepositBody: Codable { let recipient: String; let amount: Double; let reason: String? }
private struct IntentBody: Codable { let to: String; let amount: Double; let model: String }
