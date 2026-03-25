using System.Text.Json.Serialization;

namespace RemitMd;

// ─── Chain identifiers ────────────────────────────────────────────────────────

/// <summary>EVM chain IDs supported by remit.md.</summary>
public enum ChainId
{
    Base = 8453,
    BaseSepolia = 84532,
}

// ─── Status enums ─────────────────────────────────────────────────────────────

public enum InvoiceStatus { Pending, Funded, Active, Completed, Cancelled, Failed }

public enum EscrowStatus { Pending, Funded, Active, Completed, Cancelled, Failed }

public enum TabStatus { Open, Closed, Expired, Suspended }

public enum StreamStatus { Active, Paused, Closed, Completed, Cancelled }

public enum BountyStatus { Open, Closed, Awarded, Expired, Cancelled }

public enum DepositStatus { Locked, Returned, Forfeited, Expired }

// ─── Core models ──────────────────────────────────────────────────────────────

/// <summary>Result of a completed payment operation.</summary>
public record Transaction(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("tx_hash")] string? TxHash,
    [property: JsonPropertyName("from")] string? From,
    [property: JsonPropertyName("to")] string? To,
    [property: JsonPropertyName("amount")] decimal? Amount,
    [property: JsonPropertyName("fee")] decimal? Fee,
    [property: JsonPropertyName("memo")] string Memo,
    [property: JsonPropertyName("chain_id")] ChainId ChainId,
    [property: JsonPropertyName("block_number")] ulong? BlockNumber,
    [property: JsonPropertyName("created_at")] DateTimeOffset CreatedAt,
    [property: JsonPropertyName("invoice_id")] string? InvoiceId = null
);

/// <summary>Wallet status including balance, tier, and fee info.</summary>
public record WalletStatus(
    [property: JsonPropertyName("wallet")] string Wallet,
    [property: JsonPropertyName("balance")] string Balance,
    [property: JsonPropertyName("monthly_volume")] string MonthlyVolume,
    [property: JsonPropertyName("tier")] string Tier,
    [property: JsonPropertyName("fee_rate_bps")] int FeeRateBps,
    [property: JsonPropertyName("active_escrows")] int ActiveEscrows,
    [property: JsonPropertyName("active_tabs")] int ActiveTabs,
    [property: JsonPropertyName("active_streams")] int ActiveStreams,
    [property: JsonPropertyName("permit_nonce")] int? PermitNonce
);

/// <summary>Chat-style message shown on a fund/withdraw page.</summary>
public record LinkMessage(
    [property: JsonPropertyName("role")] string Role,
    [property: JsonPropertyName("text")] string Text
);

/// <summary>One-time operator link for funding or withdrawing a wallet.</summary>
public record LinkResponse(
    [property: JsonPropertyName("url")]            string Url,
    [property: JsonPropertyName("token")]          string Token,
    [property: JsonPropertyName("expires_at")]     string ExpiresAt,
    [property: JsonPropertyName("wallet_address")] string WalletAddress
);

/// <summary>Current USDC balance for a wallet address.</summary>
public record Balance(
    [property: JsonPropertyName("usdc")] decimal Usdc,
    [property: JsonPropertyName("address")] string Address,
    [property: JsonPropertyName("chain_id")] ChainId ChainId,
    [property: JsonPropertyName("updated_at")] DateTimeOffset UpdatedAt
);

/// <summary>On-chain payment reputation for an address.</summary>
public record Reputation(
    [property: JsonPropertyName("address")] string Address,
    [property: JsonPropertyName("score")] int Score,
    [property: JsonPropertyName("total_paid")] decimal TotalPaid,
    [property: JsonPropertyName("total_received")] decimal TotalReceived,
    [property: JsonPropertyName("transaction_count")] int TransactionCount,
    [property: JsonPropertyName("member_since")] DateTimeOffset MemberSince
);

/// <summary>A partial payment condition within an Escrow.</summary>
public record Milestone(
    [property: JsonPropertyName("id")] string? Id,
    [property: JsonPropertyName("description")] string Description,
    [property: JsonPropertyName("amount")] decimal Amount,
    [property: JsonPropertyName("released")] bool Released
);

/// <summary>Distributes an escrow payment among multiple recipients.</summary>
public record Split(
    [property: JsonPropertyName("recipient")] string Recipient,
    [property: JsonPropertyName("basis_points")] int BasisPoints
);

/// <summary>Escrow — holds funds until work is delivered and approved.</summary>
public record Escrow(
    [property: JsonPropertyName("invoice_id")] string Id,
    [property: JsonPropertyName("payer")] string Payer,
    [property: JsonPropertyName("payee")] string Payee,
    [property: JsonPropertyName("amount")] decimal Amount,
    [property: JsonPropertyName("fee")] decimal Fee,
    [property: JsonPropertyName("status")] EscrowStatus Status,
    [property: JsonPropertyName("memo")] string Memo,
    [property: JsonPropertyName("milestones")] IReadOnlyList<Milestone>? Milestones,
    [property: JsonPropertyName("splits")] IReadOnlyList<Split>? Splits,
    [property: JsonPropertyName("expires_at")] DateTimeOffset? ExpiresAt,
    [property: JsonPropertyName("created_at")] DateTimeOffset CreatedAt
);

/// <summary>Tab — off-chain payment channel for batched micro-payments.</summary>
public record Tab(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("payer")] string Payer,
    [property: JsonPropertyName("payee")] string Payee,
    [property: JsonPropertyName("limit")] decimal Limit,
    [property: JsonPropertyName("per_unit")] decimal PerUnit,
    [property: JsonPropertyName("spent")] decimal Spent,
    [property: JsonPropertyName("status")] TabStatus Status,
    [property: JsonPropertyName("created_at")] DateTimeOffset CreatedAt,
    [property: JsonPropertyName("expires_at")] string? ExpiresAt
);

/// <summary>A single charge against a Tab (returned by POST /tabs/{id}/charge).</summary>
public record TabCharge(
    [property: JsonPropertyName("tab_id")] string TabId,
    [property: JsonPropertyName("amount")] decimal Amount,
    [property: JsonPropertyName("cumulative")] decimal Cumulative,
    [property: JsonPropertyName("call_count")] int CallCount,
    [property: JsonPropertyName("provider_sig")] string ProviderSig
);

/// <summary>Stream — time-based payment flow (pay-per-second).</summary>
public record Stream(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("payer")] string Payer,
    [property: JsonPropertyName("payee")] string Payee,
    [property: JsonPropertyName("rate_per_second")] decimal RatePerSecond,
    [property: JsonPropertyName("max_duration")] long MaxDuration,
    [property: JsonPropertyName("max_total")] decimal? MaxTotal,
    [property: JsonPropertyName("total_streamed")] decimal TotalStreamed,
    [property: JsonPropertyName("status")] StreamStatus Status,
    [property: JsonPropertyName("started_at")] DateTimeOffset StartedAt,
    [property: JsonPropertyName("closed_at")] DateTimeOffset? ClosedAt
);

/// <summary>Bounty — a task with a USDC reward for completion.</summary>
public record Bounty(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("poster")] string Poster,
    [property: JsonPropertyName("amount")] decimal Amount,
    [property: JsonPropertyName("task")] string Task,
    [property: JsonPropertyName("status")] BountyStatus Status,
    [property: JsonPropertyName("validation")] string? Validation,
    [property: JsonPropertyName("max_attempts")] int MaxAttempts,
    [property: JsonPropertyName("submissions")] IReadOnlyList<BountySubmission>? Submissions,
    [property: JsonPropertyName("deadline")] string? Deadline,
    [property: JsonPropertyName("created_at")] DateTimeOffset CreatedAt
);

/// <summary>A submission against a bounty.</summary>
public record BountySubmission(
    [property: JsonPropertyName("id")] int Id,
    [property: JsonPropertyName("bounty_id")] string BountyId,
    [property: JsonPropertyName("submitter")] string Submitter,
    [property: JsonPropertyName("evidence_hash")] string EvidenceHash
);

/// <summary>Deposit — security deposit held as collateral.</summary>
public record Deposit(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("payer")] string Payer,
    [property: JsonPropertyName("payee")] string Payee,
    [property: JsonPropertyName("amount")] decimal Amount,
    [property: JsonPropertyName("status")] DepositStatus Status,
    [property: JsonPropertyName("expires_at")] string? ExpiresAt,
    [property: JsonPropertyName("created_at")] DateTimeOffset CreatedAt
);

/// <summary>Intent — a proposed payment awaiting negotiation.</summary>
public record Intent(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("from")] string From,
    [property: JsonPropertyName("to")] string To,
    [property: JsonPropertyName("amount")] decimal Amount,
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("expires_at")] DateTimeOffset ExpiresAt,
    [property: JsonPropertyName("created_at")] DateTimeOffset CreatedAt
);

/// <summary>Spending analytics for a wallet address.</summary>
public record SpendingSummary(
    [property: JsonPropertyName("address")] string Address,
    [property: JsonPropertyName("period")] string Period,
    [property: JsonPropertyName("total_spent")] decimal TotalSpent,
    [property: JsonPropertyName("total_fees")] decimal TotalFees,
    [property: JsonPropertyName("tx_count")] int TxCount,
    [property: JsonPropertyName("top_recipients")] IReadOnlyList<RecipientSummary> TopRecipients
);

/// <summary>A recipient entry within a SpendingSummary.</summary>
public record RecipientSummary(
    [property: JsonPropertyName("address")] string Address,
    [property: JsonPropertyName("amount")] decimal Amount
);

/// <summary>Remaining spending capacity under operator-set limits.</summary>
public record Budget(
    [property: JsonPropertyName("daily_limit")] decimal DailyLimit,
    [property: JsonPropertyName("daily_used")] decimal DailyUsed,
    [property: JsonPropertyName("daily_remaining")] decimal DailyRemaining,
    [property: JsonPropertyName("monthly_limit")] decimal MonthlyLimit,
    [property: JsonPropertyName("monthly_used")] decimal MonthlyUsed,
    [property: JsonPropertyName("monthly_remaining")] decimal MonthlyRemaining,
    [property: JsonPropertyName("per_tx_limit")] decimal PerTxLimit
);

/// <summary>A registered webhook endpoint.</summary>
public record Webhook(
    [property: JsonPropertyName("id")]         string Id,
    [property: JsonPropertyName("wallet")]     string Wallet,
    [property: JsonPropertyName("url")]        string Url,
    [property: JsonPropertyName("events")]     IReadOnlyList<string> Events,
    [property: JsonPropertyName("chains")]     IReadOnlyList<string> Chains,
    [property: JsonPropertyName("active")]     bool Active,
    [property: JsonPropertyName("created_at")] DateTimeOffset CreatedAt,
    [property: JsonPropertyName("updated_at")] DateTimeOffset UpdatedAt
);

/// <summary>EIP-2612 permit signature for gasless USDC approvals.</summary>
public record PermitSignature(
    [property: JsonPropertyName("value")] long Value,
    [property: JsonPropertyName("deadline")] long Deadline,
    [property: JsonPropertyName("v")] int V,
    [property: JsonPropertyName("r")] string R,
    [property: JsonPropertyName("s")] string S
);

/// <summary>On-chain contract addresses for the current chain.</summary>
public record ContractAddresses(
    [property: JsonPropertyName("chain_id")] long ChainId,
    [property: JsonPropertyName("usdc")] string Usdc,
    [property: JsonPropertyName("router")] string Router,
    [property: JsonPropertyName("escrow")] string Escrow,
    [property: JsonPropertyName("tab")] string Tab,
    [property: JsonPropertyName("stream")] string Stream,
    [property: JsonPropertyName("bounty")] string Bounty,
    [property: JsonPropertyName("deposit")] string Deposit,
    [property: JsonPropertyName("fee_calculator")] string FeeCalculator,
    [property: JsonPropertyName("key_registry")] string KeyRegistry,
    [property: JsonPropertyName("relayer")] string? Relayer = null
);

/// <summary>Result of a testnet mint operation.</summary>
public record MintResponse(
    [property: JsonPropertyName("tx_hash")] string TxHash,
    [property: JsonPropertyName("balance")] decimal Balance
);

/// <summary>A paginated list of transactions.</summary>
public record TransactionList(
    [property: JsonPropertyName("items")] IReadOnlyList<Transaction> Items,
    [property: JsonPropertyName("total")] int Total,
    [property: JsonPropertyName("page")] int Page,
    [property: JsonPropertyName("per_page")] int PerPage,
    [property: JsonPropertyName("has_more")] bool HasMore
);
