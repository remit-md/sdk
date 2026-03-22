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
    case pending, funded, released, cancelled, expired
}

public enum TabStatus: String, Codable, Sendable {
    case open, closed, settled
}

public enum StreamStatus: String, Codable, Sendable {
    case active, paused, ended, cancelled
}

public enum BountyStatus: String, Codable, Sendable {
    case open, awarded, expired, reclaimed
}

public enum DepositStatus: String, Codable, Sendable {
    case locked, returned, forfeited
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
    public let arbitration: String
    public let relayer: String?

    enum CodingKeys: String, CodingKey {
        case usdc, router, escrow, tab, stream, bounty, deposit, arbitration, relayer
        case chainId = "chain_id"
        case feeCalculator = "fee_calculator"
        case keyRegistry = "key_registry"
    }
}

// MARK: - Core models

public struct Transaction: Codable, Sendable {
    public let id: String
    public let from: String
    public let to: String
    public let amount: Double
    public let currency: String
    public let status: String
    public let memo: String?
    public let blockNumber: Int?
    public let txHash: String?
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, from, to, amount, currency, status, memo
        case blockNumber = "block_number"
        case txHash = "tx_hash"
        case createdAt = "created_at"
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

public struct Reputation: Codable, Sendable {
    public let address: String
    public let score: Double
    public let totalVolume: Double
    public let transactionCount: Int
    public let counterpartyCount: Int
    public let agedays: Int
    public let escrowRate: Double

    enum CodingKeys: String, CodingKey {
        case address, score
        case totalVolume = "total_volume"
        case transactionCount = "transaction_count"
        case counterpartyCount = "counterparty_count"
        case agedays = "age_days"
        case escrowRate = "escrow_rate"
    }
}

public struct Escrow: Codable, Sendable {
    public let id: String
    public let payer: String
    public let recipient: String
    public let amount: Double
    public let currency: String
    public let status: EscrowStatus
    public let conditions: String?
    public let expiresAt: Date?
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, payer, recipient, amount, currency, status, conditions
        case invoiceId = "invoice_id"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    public init(id: String, payer: String, recipient: String, amount: Double, currency: String,
                status: EscrowStatus, conditions: String?, expiresAt: Date?, createdAt: Date) {
        self.id = id; self.payer = payer; self.recipient = recipient; self.amount = amount
        self.currency = currency; self.status = status; self.conditions = conditions
        self.expiresAt = expiresAt; self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Server returns invoice_id for escrows. Fall back to id for mocks.
        if let invoiceId = try? c.decode(String.self, forKey: .invoiceId) {
            self.id = invoiceId
        } else {
            self.id = try c.decode(String.self, forKey: .id)
        }
        self.payer = (try? c.decode(String.self, forKey: .payer)) ?? ""
        self.recipient = (try? c.decode(String.self, forKey: .recipient)) ?? ""
        self.amount = (try? c.decode(Double.self, forKey: .amount)) ?? 0
        self.currency = (try? c.decode(String.self, forKey: .currency)) ?? "USDC"
        self.status = (try? c.decode(EscrowStatus.self, forKey: .status)) ?? .pending
        self.conditions = try? c.decode(String.self, forKey: .conditions)
        self.expiresAt = try? c.decode(Date.self, forKey: .expiresAt)
        self.createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(payer, forKey: .payer)
        try c.encode(recipient, forKey: .recipient)
        try c.encode(amount, forKey: .amount)
        try c.encode(currency, forKey: .currency)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(conditions, forKey: .conditions)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

public struct Tab: Codable, Sendable {
    public let id: String
    public let payer: String
    public let recipient: String
    public let limit: Double
    public let spent: Double
    public let currency: String
    public let status: TabStatus
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, payer, recipient, limit, spent, currency, status
        case createdAt = "created_at"
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
    public let recipient: String
    public let ratePerSecond: Double
    public let currency: String
    public let status: StreamStatus
    public let totalStreamed: Double
    public let startedAt: Date
    public let endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, payer, recipient, currency, status
        case ratePerSecond = "rate_per_second"
        case totalStreamed = "total_streamed"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

public struct Bounty: Codable, Sendable {
    public let id: String
    public let payer: String
    public let amount: Double
    public let currency: String
    public let description: String
    public let status: BountyStatus
    public let winner: String?
    public let expiresAt: Date?
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, payer, amount, currency, description, status, winner
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }
}

public struct BountySubmission: Codable, Sendable {
    public let id: Int
    public let bountyId: String
    public let submitter: String
    public let evidenceHash: String
    public let status: String
    public let submittedAt: String

    enum CodingKeys: String, CodingKey {
        case id, submitter, status
        case bountyId = "bounty_id"
        case evidenceHash = "evidence_hash"
        case submittedAt = "submitted_at"
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
    public let depositor: String
    public let recipient: String
    public let amount: Double
    public let currency: String
    public let status: DepositStatus
    public let reason: String?
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, depositor, recipient, amount, currency, status, reason
        case createdAt = "created_at"
    }
}

public struct Intent: Codable, Sendable {
    public let id: String
    public let from: String
    public let to: String
    public let amount: Double
    public let currency: String
    public let model: String
    public let status: String
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, from, to, amount, currency, model, status
        case expiresAt = "expires_at"
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
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, wallet, url, events, chains, active
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
