import Foundation

/// Thread-safe in-memory mock for unit testing remit.md integrations.
///
/// Zero network calls, zero real USDC. All operations complete in <1ms.
///
/// ```swift
/// let mock = MockRemit()
/// let wallet = RemitWallet(mock: mock)
///
/// mock.setBalance(100.0, for: mock.walletAddress)
///
/// let tx = try await wallet.pay(to: "0xRecipient...", amount: 5.0)
/// XCTAssertTrue(mock.wasPaid(address: "0xRecipient..."))
/// XCTAssertEqual(mock.totalPaid(to: "0xRecipient..."), 5.0)
/// ```
public final class MockRemit: @unchecked Sendable {
    private let lock = NSLock()

    // In-memory state
    private var _transactions: [Transaction] = []
    private var _balances: [String: Double] = [:]
    private var _escrows: [String: Escrow] = [:]
    private var _tabs: [String: Tab] = [:]
    private var _tabDebits: [String: [TabDebit]] = [:]
    private var _streams: [String: Stream] = [:]
    private var _bounties: [String: Bounty] = [:]
    private var _deposits: [String: Deposit] = [:]
    private var _reputations: [String: Reputation] = [:]
    private var _pendingInvoices: [String: [String: Any]] = [:]

    /// Default wallet address used by the mock signer.
    public let walletAddress = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

    public init() {}

    // MARK: - Test setup helpers

    /// Seed a balance for an address. Call before any pay/debit that needs funds.
    public func setBalance(_ amount: Double, for address: String) {
        lock.remitLock { _balances[address] = amount }
    }

    /// Seed a custom reputation score.
    public func setReputation(_ score: Double, for address: String) {
        lock.remitLock {
            _reputations[address] = Reputation(
                address: address, score: score,
                totalVolume: 0, transactionCount: 0,
                counterpartyCount: 0,
                agedays: 0, escrowRate: 0
            )
        }
    }

    // MARK: - Assertions

    public func wasPaid(address: String) -> Bool {
        lock.remitLock { _transactions.contains { $0.to == address } }
    }

    public func totalPaid(to address: String) -> Double {
        lock.remitLock {
            _transactions.filter { $0.to == address }.map(\.amount).reduce(0, +)
        }
    }

    public func transactionCount() -> Int {
        lock.remitLock { _transactions.count }
    }

    public func balance(for address: String) -> Double {
        lock.remitLock { _balances[address, default: 1000.0] }
    }

    public func reset() {
        lock.remitLock {
            _transactions.removeAll()
            _balances.removeAll()
            _escrows.removeAll()
            _tabs.removeAll()
            _tabDebits.removeAll()
            _streams.removeAll()
            _bounties.removeAll()
            _deposits.removeAll()
            _reputations.removeAll()
        }
    }

    // MARK: - Internal handler (called by MockTransport)

    func handle<T: Decodable>(method: String, path: String, body: (any Encodable)?) throws -> T {
        // Route to handler based on path prefix
        let parts = path.split(separator: "/").map(String.init)

        if path == "/api/v1/payments/direct" {
            return try cast(handlePay(body: body))
        }
        if path.hasPrefix("/api/v1/balance/") {
            return try cast(handleBalance(address: parts.last ?? walletAddress))
        }
        if path == "/api/v1/invoices" && method == "POST" {
            return try cast(handleCreateInvoice(body: body))
        }
        if path == "/api/v1/escrows" && method == "POST" {
            return try cast(handleCreateEscrow(body: body))
        }
        if path.hasPrefix("/api/v1/escrows/") && path.hasSuffix("/claim-start") && method == "POST" {
            return try cast(handleGetEscrow(id: parts[parts.count - 2]))
        }
        if path.hasPrefix("/api/v1/escrows/") && method == "GET" {
            return try cast(handleGetEscrow(id: parts.last ?? ""))
        }
        if path.hasSuffix("/release") && method == "POST" {
            return try cast(handleReleaseEscrow(id: parts[parts.count - 2]))
        }
        if path.hasSuffix("/cancel") && method == "POST" {
            return try cast(handleCancelEscrow(id: parts[parts.count - 2]))
        }
        if path == "/api/v1/tabs" && method == "POST" {
            return try cast(handleCreateTab(body: body))
        }
        if path.hasSuffix("/charge") && method == "POST" {
            return try cast(handleDebitTab(id: parts[parts.count - 2], body: body))
        }
        if path.hasPrefix("/api/v1/tabs/") && path.hasSuffix("/close") && method == "POST" {
            return try cast(handleCloseTab(id: parts[parts.count - 2], body: body))
        }
        if path == "/api/v1/streams" && method == "POST" {
            return try cast(handleCreateStream(body: body))
        }
        if path.hasPrefix("/api/v1/streams/") && path.hasSuffix("/close") && method == "POST" {
            return try cast(handleStopStream(id: parts[parts.count - 2]))
        }
        if path == "/api/v1/bounties" && method == "POST" {
            return try cast(handleCreateBounty(body: body))
        }
        if path.hasPrefix("/api/v1/bounties/") && path.hasSuffix("/submit") && method == "POST" {
            return try cast(handleSubmitBounty(id: parts[parts.count - 2], body: body))
        }
        if path.hasSuffix("/award") && method == "POST" {
            return try cast(handleAwardBounty(id: parts[parts.count - 2], body: body))
        }
        if path == "/api/v1/deposits" && method == "POST" {
            return try cast(handleCreateDeposit(body: body))
        }
        if path.hasPrefix("/api/v1/deposits/") && path.hasSuffix("/return") && method == "POST" {
            return try cast(handleReturnDeposit(id: parts[parts.count - 2]))
        }
        if path.hasPrefix("/api/v1/reputation/") {
            return try cast(handleReputation(address: parts.last ?? walletAddress))
        }
        if path.hasPrefix("/api/v1/spending/") {
            return try cast(handleSpendingSummary(address: parts.last ?? walletAddress))
        }
        if path.hasPrefix("/api/v1/history/") {
            return try cast(handleHistory(address: parts.last ?? walletAddress))
        }
        if path.hasPrefix("/api/v1/budget/") {
            return try cast(handleBudget(address: parts.last ?? walletAddress))
        }
        if path == "/api/v1/intent" && method == "POST" {
            return try cast(handleIntent(body: body))
        }
        throw RemitError(RemitError.serverError, "MockRemit: unhandled route \(method) \(path)")
    }

    // MARK: - Route handlers

    private func handlePay(body: (any Encodable)?) throws -> Transaction {
        let b = try jsonDecode(PayBody.self, from: body)
        try validate(address: b.to)
        try validate(amount: b.amount)
        return lock.remitLock {
            let tx = Transaction(
                id: newID("tx"), from: walletAddress, to: b.to,
                amount: b.amount, currency: "USDC", status: "confirmed",
                memo: b.memo, blockNumber: 1, txHash: "0x" + String(repeating: "ab", count: 32),
                createdAt: Date()
            )
            _transactions.append(tx)
            return tx
        }
    }

    private func handleBalance(address: String) throws -> Balance {
        return lock.remitLock {
            Balance(address: address, balance: _balances[address, default: 1000.0],
                    currency: "USDC", chainId: 84532)
        }
    }

    private struct InvoiceBody: Codable { let id: String; let to_agent: String; let amount: String; let task: String? }
    private struct InvoiceResp: Codable { let id: String; let status: String }

    private func handleCreateInvoice(body: (any Encodable)?) throws -> InvoiceResp {
        let b = try jsonDecode(InvoiceBody.self, from: body)
        lock.remitLock {
            _pendingInvoices[b.id] = ["to_agent": b.to_agent, "amount": b.amount, "task": b.task ?? ""]
        }
        return InvoiceResp(id: b.id, status: "pending")
    }

    private struct EscrowFundBody: Codable { let invoice_id: String }

    private func handleCreateEscrow(body: (any Encodable)?) throws -> Escrow {
        let b = try jsonDecode(EscrowFundBody.self, from: body)
        return try lock.remitLock {
            guard let inv = _pendingInvoices.removeValue(forKey: b.invoice_id) else {
                throw RemitError.notFound(RemitError.escrowNotFound, b.invoice_id)
            }
            let recipient = inv["to_agent"] as? String ?? ""
            let amount = Double(inv["amount"] as? String ?? "0") ?? 0
            let conditions = inv["task"] as? String
            let e = Escrow(id: b.invoice_id, payer: walletAddress, recipient: recipient,
                           amount: amount, currency: "USDC", status: .pending,
                           conditions: conditions, expiresAt: nil, createdAt: Date())
            _escrows[e.id] = e
            return e
        }
    }

    private func handleGetEscrow(id: String) throws -> Escrow {
        guard let e = lock.remitLock({ _escrows[id] }) else {
            throw RemitError.notFound(RemitError.escrowNotFound, id)
        }
        return e
    }

    private func handleReleaseEscrow(id: String) throws -> Escrow {
        return try lock.remitLock {
            guard let e = _escrows[id] else {
                throw RemitError.notFound(RemitError.escrowNotFound, id)
            }
            if e.status == .completed { throw RemitError(RemitError.escrowAlreadyCompleted, "escrow \(id) already completed") }
            let updated = Escrow(id: e.id, payer: e.payer, recipient: e.recipient,
                                 amount: e.amount, currency: e.currency, status: .completed,
                                 conditions: e.conditions, expiresAt: e.expiresAt, createdAt: e.createdAt)
            _escrows[id] = updated
            return updated
        }
    }

    private func handleCancelEscrow(id: String) throws -> Escrow {
        return try lock.remitLock {
            guard let e = _escrows[id] else {
                throw RemitError.notFound(RemitError.escrowNotFound, id)
            }
            let updated = Escrow(id: e.id, payer: e.payer, recipient: e.recipient,
                                 amount: e.amount, currency: e.currency, status: .cancelled,
                                 conditions: e.conditions, expiresAt: e.expiresAt, createdAt: e.createdAt)
            _escrows[id] = updated
            return updated
        }
    }

    private func handleCreateTab(body: (any Encodable)?) throws -> Tab {
        let b = try jsonDecode(TabBody.self, from: body)
        try validate(address: b.provider)
        try validate(amount: b.limit_amount)
        return lock.remitLock {
            let t = Tab(id: newID("tab"), payer: walletAddress, recipient: b.provider,
                        limit: b.limit_amount, spent: 0, currency: "USDC", status: .open, createdAt: Date())
            _tabs[t.id] = t
            return t
        }
    }

    private func handleDebitTab(id: String, body: (any Encodable)?) throws -> TabCharge {
        let b = try jsonDecode(ChargeTabBody.self, from: body)
        try validate(amount: b.amount)
        return try lock.remitLock {
            guard let t = _tabs[id] else { throw RemitError.notFound(RemitError.tabNotFound, id) }
            let newSpent = t.spent + b.amount
            if newSpent > t.limit {
                throw RemitError(RemitError.tabLimitExceeded,
                    "charge would bring spent to \(newSpent) USDC, exceeding limit of \(t.limit) USDC")
            }
            let updated = Tab(id: t.id, payer: t.payer, recipient: t.recipient,
                              limit: t.limit, spent: newSpent, currency: t.currency,
                              status: t.status, createdAt: t.createdAt)
            _tabs[id] = updated
            _counter += 1
            return TabCharge(id: _counter, tabId: id, amount: b.amount,
                             cumulative: b.cumulative, callCount: b.call_count,
                             providerSig: b.provider_sig, chargedAt: ISO8601DateFormatter().string(from: Date()))
        }
    }

    private func handleCloseTab(id: String, body: (any Encodable)?) throws -> Tab {
        return try lock.remitLock {
            guard let t = _tabs[id] else { throw RemitError.notFound(RemitError.tabNotFound, id) }
            let updated = Tab(id: t.id, payer: t.payer, recipient: t.recipient,
                              limit: t.limit, spent: t.spent, currency: t.currency,
                              status: .closed, createdAt: t.createdAt)
            _tabs[id] = updated
            return updated
        }
    }

    private func handleCreateStream(body: (any Encodable)?) throws -> Stream {
        let b = try jsonDecode(StreamBody.self, from: body)
        try validate(address: b.payee)
        guard b.rate_per_second > 0 else {
            throw RemitError(RemitError.invalidAmount, "rate_per_second must be positive")
        }
        return lock.remitLock {
            let s = Stream(id: newID("stream"), payer: walletAddress, recipient: b.payee,
                           ratePerSecond: b.rate_per_second, currency: "USDC", status: .active,
                           totalStreamed: 0, startedAt: Date(), endedAt: nil)
            _streams[s.id] = s
            return s
        }
    }

    private func handleStopStream(id: String) throws -> Stream {
        return try lock.remitLock {
            guard let s = _streams[id] else { throw RemitError.notFound(RemitError.streamNotFound, id) }
            let updated = Stream(id: s.id, payer: s.payer, recipient: s.recipient,
                                 ratePerSecond: s.ratePerSecond, currency: s.currency,
                                 status: .closed, totalStreamed: s.totalStreamed,
                                 startedAt: s.startedAt, endedAt: Date())
            _streams[id] = updated
            return updated
        }
    }

    private func handleCreateBounty(body: (any Encodable)?) throws -> Bounty {
        let b = try jsonDecode(BountyBody.self, from: body)
        try validate(amount: b.amount)
        return lock.remitLock {
            let bounty = Bounty(id: newID("bounty"), payer: walletAddress,
                                amount: b.amount, currency: "USDC",
                                description: b.task_description, status: .open,
                                winner: nil, expiresAt: nil, createdAt: Date())
            _bounties[bounty.id] = bounty
            return bounty
        }
    }

    private struct SubmitBountyBody: Codable { let evidence_hash: String }

    private func handleSubmitBounty(id: String, body: (any Encodable)?) throws -> BountySubmission {
        let b = try jsonDecode(SubmitBountyBody.self, from: body)
        return try lock.remitLock {
            guard _bounties[id] != nil else { throw RemitError.notFound(RemitError.bountyNotFound, id) }
            _counter += 1
            return BountySubmission(id: _counter, bountyId: id, submitter: walletAddress,
                                    evidenceHash: b.evidence_hash, status: "pending",
                                    submittedAt: ISO8601DateFormatter().string(from: Date()))
        }
    }

    private func handleAwardBounty(id: String, body: (any Encodable)?) throws -> Bounty {
        let b = try jsonDecode(AwardBody.self, from: body)
        return try lock.remitLock {
            guard let bounty = _bounties[id] else { throw RemitError.notFound(RemitError.bountyNotFound, id) }
            if bounty.status == .awarded { throw RemitError(RemitError.bountyAlreadyAwarded, "bounty \(id) already awarded") }
            let updated = Bounty(id: bounty.id, payer: bounty.payer, amount: bounty.amount,
                                 currency: bounty.currency, description: bounty.description,
                                 status: .awarded, winner: "submission_\(b.submission_id)",
                                 expiresAt: bounty.expiresAt, createdAt: bounty.createdAt)
            _bounties[id] = updated
            return updated
        }
    }

    private func handleCreateDeposit(body: (any Encodable)?) throws -> Deposit {
        let b = try jsonDecode(DepositBody.self, from: body)
        try validate(address: b.provider)
        try validate(amount: b.amount)
        return lock.remitLock {
            let d = Deposit(id: newID("dep"), depositor: walletAddress, recipient: b.provider,
                            amount: b.amount, currency: "USDC", status: .locked,
                            reason: nil, createdAt: Date())
            _deposits[d.id] = d
            return d
        }
    }

    private func handleReturnDeposit(id: String) throws -> Transaction {
        return try lock.remitLock {
            guard let d = _deposits[id] else { throw RemitError.notFound(RemitError.depositNotFound, id) }
            let updated = Deposit(id: d.id, depositor: d.depositor, recipient: d.recipient,
                                  amount: d.amount, currency: d.currency, status: .returned,
                                  reason: d.reason, createdAt: d.createdAt)
            _deposits[id] = updated
            return Transaction(
                id: newID("tx"), from: d.recipient, to: d.depositor,
                amount: d.amount, currency: "USDC", status: "confirmed",
                memo: "deposit returned", blockNumber: 1,
                txHash: "0x" + String(repeating: "cd", count: 32),
                createdAt: Date()
            )
        }
    }

    private func handleReputation(address: String) throws -> Reputation {
        return lock.remitLock {
            _reputations[address] ?? Reputation(
                address: address, score: 0.72, totalVolume: 1500.0,
                transactionCount: 47,
                counterpartyCount: 12, agedays: 90, escrowRate: 0.15
            )
        }
    }

    private func handleSpendingSummary(address: String) throws -> SpendingSummary {
        return SpendingSummary(
            address: address, totalSpent: 234.50, totalReceived: 890.00,
            currency: "USDC", period: "30d", transactionCount: 47,
            topCounterparties: ["0xAlice...", "0xBob..."]
        )
    }

    private func handleHistory(address: String) throws -> TransactionList {
        return lock.remitLock {
            let txs = _transactions.filter { $0.from == address || $0.to == address }
            return TransactionList(transactions: txs, total: txs.count, page: 1, perPage: 50)
        }
    }

    private func handleBudget(address: String) throws -> Budget {
        return Budget(address: address, dailyLimit: 500.0, spent: 23.50,
                      remaining: 476.50, currency: "USDC")
    }

    private func handleIntent(body: (any Encodable)?) throws -> Intent {
        let b = try jsonDecode(IntentBody.self, from: body)
        try validate(address: b.to)
        try validate(amount: b.amount)
        return Intent(id: newID("intent"), from: walletAddress, to: b.to,
                      amount: b.amount, currency: "USDC", model: b.model,
                      status: "pending",
                      expiresAt: Date().addingTimeInterval(300))
    }

    // MARK: - Helpers

    private var _counter = 0
    private func newID(_ prefix: String) -> String {
        _counter += 1
        return "\(prefix)_\(String(format: "%08x", _counter))"
    }

    private func validate(address: String) throws {
        guard address.hasPrefix("0x"), address.count == 42,
              address.dropFirst(2).allSatisfy({ $0.isHexDigit }) else {
            throw RemitError.invalidAddress(address)
        }
    }

    private func validate(amount: Double) throws {
        guard amount > 0 else {
            throw RemitError.invalidAmount(amount, reason: "amount must be positive")
        }
    }

    private func jsonDecode<T: Decodable>(_ type: T.Type, from body: (any Encodable)?) throws -> T {
        guard let body else { throw RemitError(RemitError.serverError, "missing request body") }
        let data = try encodeBody(body)
        return try JSONDecoder().decode(type, from: data)
    }

    private func cast<T: Decodable>(_ value: some Encodable) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Request body structs (internal)

private struct PayBody: Codable { let to: String; let amount: Double; let memo: String? }
private struct EscrowBody: Codable { let recipient: String; let amount: Double; let conditions: String? }
private struct TabBody: Codable { let provider: String; let limit_amount: Double; let per_unit: Double?; let expiry: Int? }
private struct ChargeTabBody: Codable { let amount: Double; let cumulative: Double; let call_count: Int; let provider_sig: String }
private struct CloseTabBody: Codable { let final_amount: Double?; let provider_sig: String? }
private struct StreamBody: Codable { let payee: String; let rate_per_second: Double; let max_total: Double? }
private struct BountyBody: Codable { let amount: Double; let task_description: String; let deadline: Int?; let max_attempts: Int? }
private struct AwardBody: Codable { let submission_id: Int }
private struct DepositBody: Codable { let provider: String; let amount: Double; let expiry: Int? }
private struct IntentBody: Codable { let to: String; let amount: Double; let model: String }

extension NSLock {
    /// Acquire the lock, run body, release. Named `remitLock` to avoid conflict with
    /// any platform-provided `withLock` on `NSLocking`.
    @discardableResult
    fileprivate func remitLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
