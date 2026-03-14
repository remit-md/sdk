import Foundation

// MARK: - Chain IDs

public enum RemitChain: Int, Codable, Sendable {
    case base        = 8453
    case baseSepolia = 84532

    var baseURL: String {
        switch self {
        case .base:        return "https://api.remit.md"
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
        case expiresAt = "expires_at"
        case createdAt = "created_at"
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
