import Foundation

// MARK: - Chain IDs

public enum RemitChain: Int, Codable, Sendable {
    case base        = 8453
    case baseSepolia = 84532

    var baseURL: String {
        switch self {
        case .base:        return "https://remit.md"
        case .baseSepolia: return "https://testnet.remit.md"
        }
    }

    /// The chain name string sent in API request bodies.
    public var chainName: String {
        switch self {
        case .base:        return "base"
        case .baseSepolia: return "base-sepolia"
        }
    }
}

// MARK: - Status enums

public enum EscrowStatus: String, Codable, Sendable {
    case pending, funded, active, completed, cancelled, failed
}

public enum TabStatus: String, Codable, Sendable {
    case open, closed, expired, suspended
}

public enum StreamStatus: String, Codable, Sendable {
    case active, closed, completed, paused, cancelled
}

public enum BountyStatus: String, Codable, Sendable {
    case open, closed, awarded, expired, cancelled
}

public enum DepositStatus: String, Codable, Sendable {
    case locked, returned, forfeited, expired
}

// MARK: - Permit & Contract Addresses

/// EIP-2612 permit signature for gasless USDC approval.
public struct PermitSignature: Codable, Sendable {
    public let value: Double
    public let deadline: Int
    public let v: Int
    public let r: String
    public let s: String

    public init(value: Double, deadline: Int, v: Int, r: String, s: String) {
        self.value = value
        self.deadline = deadline
        self.v = v
        self.r = r
        self.s = s
    }
}

/// Contract addresses returned by GET /contracts.
public struct ContractAddresses: Codable, Sendable {
    public let chainId: Int
    public let usdc: String
    public let router: String
    public let escrow: String
    public let tab: String
    public let stream: String
    public let bounty: String
    public let deposit: String
    public let feeCalculator: String
    public let keyRegistry: String
    public let relayer: String?

    enum CodingKeys: String, CodingKey {
        case usdc, router, escrow, tab, stream, bounty, deposit, relayer
        case chainId = "chain_id"
        case feeCalculator = "fee_calculator"
        case keyRegistry = "key_registry"
    }
}

// MARK: - Core models

public struct Transaction: Codable, Sendable {
    public let invoiceId: String?
    public let txHash: String?
    public let chain: String
    public let status: String
    public let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case invoiceId = "invoice_id"
        case txHash = "tx_hash"
        case chain, status
        case createdAt = "created_at"
    }

    public init(invoiceId: String? = nil, txHash: String? = nil, chain: String = "base",
                status: String = "confirmed", createdAt: Double = Date().timeIntervalSince1970) {
        self.invoiceId = invoiceId; self.txHash = txHash; self.chain = chain
        self.status = status; self.createdAt = createdAt
    }
}

public struct Balance: Codable, Sendable {
    public let address: String
    public let balance: Double
    public let currency: String
    public let chainId: Int

    enum CodingKeys: String, CodingKey {
        case address, balance, currency
        case chainId = "chain_id"
    }
}

public struct WalletStatus: Codable, Sendable {
    public let address: String
    public let balance: Double
    public let chainId: Int
    public let permitNonce: Int?
    public let monthlyVolume: Double?
    public let feeRate: Int?

    enum CodingKeys: String, CodingKey {
        case address, balance
        case chainId = "chain_id"
        case permitNonce = "permit_nonce"
        case monthlyVolume = "monthly_volume"
        case feeRate = "fee_rate"
    }
}

public struct Reputation: Codable, Sendable {
    public let address: String
    public let score: Double
    public let totalVolume: Double
    public let transactionCount: Int
    public let counterpartyCount: Int
    public let agedays: Int
    public let escrowRate: Double

    enum CodingKeys: String, CodingKey {
        case address, wallet, score
        case totalVolume = "total_volume"
        case transactionCount = "transaction_count"
        case counterpartyCount = "counterparty_count"
        case agedays = "age_days"
        case escrowRate = "escrow_rate"
    }

    public init(
        address: String, score: Double, totalVolume: Double,
        transactionCount: Int, counterpartyCount: Int, agedays: Int, escrowRate: Double
    ) {
        self.address = address; self.score = score; self.totalVolume = totalVolume
        self.transactionCount = transactionCount; self.counterpartyCount = counterpartyCount
        self.agedays = agedays; self.escrowRate = escrowRate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let wallet = try? container.decode(String.self, forKey: .wallet) {
            self.address = wallet
        } else {
            self.address = try container.decode(String.self, forKey: .address)
        }
        self.score = try container.decode(Double.self, forKey: .score)
        self.totalVolume = try container.decode(Double.self, forKey: .totalVolume)
        self.transactionCount = try container.decode(Int.self, forKey: .transactionCount)
        self.counterpartyCount = try container.decode(Int.self, forKey: .counterpartyCount)
        self.agedays = try container.decode(Int.self, forKey: .agedays)
        self.escrowRate = try container.decode(Double.self, forKey: .escrowRate)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(address, forKey: .address)
        try container.encode(score, forKey: .score)
        try container.encode(totalVolume, forKey: .totalVolume)
        try container.encode(transactionCount, forKey: .transactionCount)
        try container.encode(counterpartyCount, forKey: .counterpartyCount)
        try container.encode(agedays, forKey: .agedays)
        try container.encode(escrowRate, forKey: .escrowRate)
    }
}

public struct Escrow: Codable, Sendable {
    public let id: String
    public let payer: String
    public let payee: String
    public let amount: Double
    public let status: EscrowStatus
    public let txHash: String?
    public let chain: String?
    public let milestoneIndex: Int?
    public let claimStartedAt: Double?
    public let evidenceUri: String?
    public let expiresAt: Double?
    public let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, payer, payee, amount, status
        case invoiceId = "invoice_id"
        case txHash = "tx_hash"
        case chain
        case milestoneIndex = "milestone_index"
        case claimStartedAt = "claim_started_at"
        case evidenceUri = "evidence_uri"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    public init(id: String, payer: String, payee: String, amount: Double,
                status: EscrowStatus, txHash: String? = nil, chain: String? = nil,
                milestoneIndex: Int? = nil, claimStartedAt: Double? = nil,
                evidenceUri: String? = nil, expiresAt: Double? = nil,
                createdAt: Double = Date().timeIntervalSince1970) {
        self.id = id; self.payer = payer; self.payee = payee; self.amount = amount
        self.status = status; self.txHash = txHash; self.chain = chain
        self.milestoneIndex = milestoneIndex; self.claimStartedAt = claimStartedAt
        self.evidenceUri = evidenceUri; self.expiresAt = expiresAt; self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Server returns invoice_id for escrows. Fall back to id for mocks.
        if let invoiceId = try? c.decode(String.self, forKey: .invoiceId) {
            self.id = invoiceId
        } else {
            self.id = try c.decode(String.self, forKey: .id)
        }
        self.payer = try c.decode(String.self, forKey: .payer)
        self.payee = try c.decode(String.self, forKey: .payee)
        self.amount = try c.decode(Double.self, forKey: .amount)
        self.status = (try? c.decode(EscrowStatus.self, forKey: .status)) ?? .pending
        self.txHash = try? c.decode(String.self, forKey: .txHash)
        self.chain = try? c.decode(String.self, forKey: .chain)
        self.milestoneIndex = try? c.decode(Int.self, forKey: .milestoneIndex)
        self.claimStartedAt = try? c.decode(Double.self, forKey: .claimStartedAt)
        self.evidenceUri = try? c.decode(String.self, forKey: .evidenceUri)
        self.expiresAt = try? c.decode(Double.self, forKey: .expiresAt)
        self.createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? Date().timeIntervalSince1970
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(payer, forKey: .payer)
        try c.encode(payee, forKey: .payee)
        try c.encode(amount, forKey: .amount)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(txHash, forKey: .txHash)
        try c.encodeIfPresent(chain, forKey: .chain)
        try c.encodeIfPresent(milestoneIndex, forKey: .milestoneIndex)
        try c.encodeIfPresent(claimStartedAt, forKey: .claimStartedAt)
        try c.encodeIfPresent(evidenceUri, forKey: .evidenceUri)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

public struct Tab: Codable, Sendable {
    public let id: String
    public let payer: String
    public let payee: String
    public let limit: Double
    public let spent: Double
    public let perUnit: Double?
    public let status: TabStatus
    public let chain: String?
    public let expiresAt: Double?
    public let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, payer, payee, limit, spent, status, chain
        case perUnit = "per_unit"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    public init(id: String, payer: String, payee: String, limit: Double, spent: Double,
                perUnit: Double? = nil, status: TabStatus, chain: String? = nil,
                expiresAt: Double? = nil, createdAt: Double = Date().timeIntervalSince1970) {
        self.id = id; self.payer = payer; self.payee = payee; self.limit = limit
        self.spent = spent; self.perUnit = perUnit; self.status = status
        self.chain = chain; self.expiresAt = expiresAt; self.createdAt = createdAt
    }
}

public struct TabDebit: Codable, Sendable {
    public let tabId: String
    public let debitId: String
    public let amount: Double
    public let memo: String?
    public let spentAfter: Double

    enum CodingKeys: String, CodingKey {
        case tabId = "tab_id"
        case debitId = "debit_id"
        case amount, memo
        case spentAfter = "spent_after"
    }
}

public struct Stream: Codable, Sendable {
    public let id: String
    public let payer: String
    public let payee: String
    public let ratePerSecond: Double
    public let status: StreamStatus
    public let totalStreamed: Double
    public let maxDuration: Double?
    public let maxTotal: Double?
    public let chain: String?
    public let startedAt: Double
    public let closedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, payer, payee, status, chain
        case ratePerSecond = "rate_per_second"
        case totalStreamed = "total_streamed"
        case maxDuration = "max_duration"
        case maxTotal = "max_total"
        case startedAt = "started_at"
        case closedAt = "closed_at"
    }

    public init(id: String, payer: String, payee: String, ratePerSecond: Double,
                status: StreamStatus, totalStreamed: Double,
                maxDuration: Double? = nil, maxTotal: Double? = nil,
                chain: String? = nil, startedAt: Double = Date().timeIntervalSince1970,
                closedAt: Double? = nil) {
        self.id = id; self.payer = payer; self.payee = payee
        self.ratePerSecond = ratePerSecond; self.status = status
        self.totalStreamed = totalStreamed; self.maxDuration = maxDuration
        self.maxTotal = maxTotal; self.chain = chain
        self.startedAt = startedAt; self.closedAt = closedAt
    }
}

public struct Bounty: Codable, Sendable {
    public let id: String
    public let poster: String
    public let amount: Double
    public let task: String
    public let status: BountyStatus
    public let winner: String?
    public let submissions: [BountySubmission]?
    public let validation: String?
    public let maxAttempts: Int?
    public let chain: String?
    public let deadline: Double?
    public let expiresAt: Double?
    public let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, poster, amount, task, status, winner, submissions, validation, chain, deadline
        case maxAttempts = "max_attempts"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    public init(id: String, poster: String, amount: Double, task: String,
                status: BountyStatus, winner: String? = nil,
                submissions: [BountySubmission]? = nil, validation: String? = nil,
                maxAttempts: Int? = nil, chain: String? = nil,
                deadline: Double? = nil, expiresAt: Double? = nil,
                createdAt: Double = Date().timeIntervalSince1970) {
        self.id = id; self.poster = poster; self.amount = amount; self.task = task
        self.status = status; self.winner = winner; self.submissions = submissions
        self.validation = validation; self.maxAttempts = maxAttempts; self.chain = chain
        self.deadline = deadline; self.expiresAt = expiresAt; self.createdAt = createdAt
    }
}

public struct BountySubmission: Codable, Sendable {
    public let id: Int
    public let bountyId: String
    public let submitter: String
    public let evidenceUri: String
    public let accepted: Bool?
    public let submittedAt: String

    enum CodingKeys: String, CodingKey {
        case id, submitter, accepted
        case bountyId = "bounty_id"
        case evidenceUri = "evidence_uri"
        case submittedAt = "submitted_at"
    }

    public init(id: Int, bountyId: String, submitter: String, evidenceUri: String,
                accepted: Bool? = nil, submittedAt: String = "") {
        self.id = id; self.bountyId = bountyId; self.submitter = submitter
        self.evidenceUri = evidenceUri; self.accepted = accepted; self.submittedAt = submittedAt
    }
}

public struct TabCharge: Codable, Sendable {
    public let id: Int
    public let tabId: String
    public let amount: Double
    public let cumulative: Double
    public let callCount: Int
    public let providerSig: String
    public let chargedAt: String

    enum CodingKeys: String, CodingKey {
        case id, amount, cumulative
        case tabId = "tab_id"
        case callCount = "call_count"
        case providerSig = "provider_sig"
        case chargedAt = "charged_at"
    }
}

public struct Deposit: Codable, Sendable {
    public let id: String
    public let payer: String
    public let payee: String
    public let amount: Double
    public let status: DepositStatus
    public let chain: String?
    public let expiresAt: Double?
    public let releasedAt: Double?
    public let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, payer, payee, amount, status, chain
        case expiresAt = "expires_at"
        case releasedAt = "released_at"
        case createdAt = "created_at"
    }

    public init(id: String, payer: String, payee: String, amount: Double,
                status: DepositStatus, chain: String? = nil,
                expiresAt: Double? = nil, releasedAt: Double? = nil,
                createdAt: Double = Date().timeIntervalSince1970) {
        self.id = id; self.payer = payer; self.payee = payee; self.amount = amount
        self.status = status; self.chain = chain; self.expiresAt = expiresAt
        self.releasedAt = releasedAt; self.createdAt = createdAt
    }
}

public struct WalletSettings: Codable, Sendable {
    public let wallet: String
    public let displayName: String?

    enum CodingKeys: String, CodingKey {
        case wallet
        case displayName = "display_name"
    }
}

public struct Budget: Codable, Sendable {
    public let address: String
    public let dailyLimit: Double
    public let spent: Double
    public let remaining: Double
    public let currency: String

    enum CodingKeys: String, CodingKey {
        case address, spent, remaining, currency
        case dailyLimit = "daily_limit"
    }
}

public struct SpendingSummary: Codable, Sendable {
    public let address: String
    public let totalSpent: Double
    public let totalReceived: Double
    public let currency: String
    public let period: String
    public let transactionCount: Int
    public let topCounterparties: [String]

    enum CodingKeys: String, CodingKey {
        case address, currency, period
        case totalSpent = "total_spent"
        case totalReceived = "total_received"
        case transactionCount = "transaction_count"
        case topCounterparties = "top_counterparties"
    }
}

public struct TransactionList: Codable, Sendable {
    public let transactions: [Transaction]
    public let total: Int
    public let page: Int
    public let perPage: Int

    enum CodingKeys: String, CodingKey {
        case transactions, total, page
        case perPage = "per_page"
    }
}

public struct LinkResponse: Codable, Sendable {
    public let url: String
    public let token: String
    public let expiresAt: String
    public let walletAddress: String

    enum CodingKeys: String, CodingKey {
        case url, token
        case expiresAt = "expires_at"
        case walletAddress = "wallet_address"
    }
}

public struct Webhook: Codable, Sendable {
    public let id: String
    public let wallet: String
    public let url: String
    public let events: [String]
    public let chains: [String]
    public let active: Bool
    public let secret: String?
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, wallet, url, events, chains, active, secret
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
