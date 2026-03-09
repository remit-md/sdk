use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

/// EVM chain IDs supported by remit.md.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ChainId(pub u64);

impl ChainId {
    /// Base mainnet
    pub const BASE: ChainId = ChainId(8453);
    /// Base Sepolia testnet
    pub const BASE_SEPOLIA: ChainId = ChainId(84532);
    /// Arbitrum One
    pub const ARBITRUM: ChainId = ChainId(42161);
    /// Optimism
    pub const OPTIMISM: ChainId = ChainId(10);
}

impl std::fmt::Display for ChainId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

// ─── Status enums ────────────────────────────────────────────────────────────

/// Status of an escrow payment.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EscrowStatus {
    Pending,
    Funded,
    Released,
    Cancelled,
    Disputed,
    Expired,
}

/// Status of a payment channel (tab).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TabStatus {
    Open,
    Closed,
    Settled,
}

/// Status of a payment stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum StreamStatus {
    Active,
    Paused,
    Ended,
    Cancelled,
}

/// Status of a bounty.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BountyStatus {
    Open,
    Awarded,
    Expired,
    Reclaimed,
}

/// Status of a security deposit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DepositStatus {
    Locked,
    Returned,
    Forfeited,
}

// ─── Core types ──────────────────────────────────────────────────────────────

/// Result of any payment operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Transaction {
    pub id: String,
    pub tx_hash: String,
    pub from: String,
    pub to: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub amount: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub fee: Decimal,
    #[serde(default)]
    pub memo: String,
    pub chain_id: ChainId,
    #[serde(default)]
    pub block_number: u64,
    pub created_at: DateTime<Utc>,
}

/// Current USDC balance of a wallet.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Balance {
    #[serde(with = "rust_decimal::serde::float")]
    pub usdc: Decimal,
    pub address: String,
    pub chain_id: ChainId,
    pub updated_at: DateTime<Utc>,
}

/// An agent's on-chain payment reputation score (0–1000).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Reputation {
    pub address: String,
    /// Score from 0 (no history) to 1000 (perfect record).
    pub score: u32,
    #[serde(with = "rust_decimal::serde::float")]
    pub total_paid: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub total_received: Decimal,
    pub transaction_count: u64,
    pub dispute_rate: f64,
    pub member_since: DateTime<Utc>,
}

/// A partial payment condition within an escrow.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Milestone {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub description: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub amount: Decimal,
    #[serde(default)]
    pub released: bool,
}

/// Distributes an escrow payment among multiple recipients.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Split {
    pub recipient: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub amount: Decimal,
}

/// Holds USDC until conditions are met.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Escrow {
    pub id: String,
    pub payer: String,
    pub payee: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub amount: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub fee: Decimal,
    pub status: EscrowStatus,
    #[serde(default)]
    pub memo: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub milestones: Vec<Milestone>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub splits: Vec<Split>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

/// Off-chain payment channel for batched micro-payments.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tab {
    pub id: String,
    pub opener: String,
    pub counterpart: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub limit: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub used: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub remaining: Decimal,
    pub status: TabStatus,
    pub created_at: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub closes_at: Option<DateTime<Utc>>,
}

/// A single charge against a Tab.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TabDebit {
    pub tab_id: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub amount: Decimal,
    pub memo: String,
    pub sequence: u64,
    pub signature: String,
}

/// Time-based payment stream (pay-per-second).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Stream {
    pub id: String,
    pub sender: String,
    pub recipient: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub rate_per_sec: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub deposited: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub withdrawn: Decimal,
    pub status: StreamStatus,
    pub started_at: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ends_at: Option<DateTime<Utc>>,
}

/// A task with a USDC reward for completion.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Bounty {
    pub id: String,
    pub poster: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub award: Decimal,
    pub description: String,
    pub status: BountyStatus,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub winner: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

/// Security deposit held as collateral.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Deposit {
    pub id: String,
    pub depositor: String,
    pub beneficiary: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub amount: Decimal,
    pub status: DepositStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

/// A proposed payment awaiting negotiation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Intent {
    pub id: String,
    pub from: String,
    pub to: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub amount: Decimal,
    #[serde(rename = "type")]
    pub payment_type: String,
    pub expires_at: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
}

/// Spending analytics for a wallet.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpendingSummary {
    pub address: String,
    pub period: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub total_spent: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub total_fees: Decimal,
    pub tx_count: u64,
    #[serde(default)]
    pub top_recipients: Vec<TopRecipient>,
}

/// A top recipient entry within SpendingSummary.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TopRecipient {
    pub address: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub amount: Decimal,
}

/// Remaining spending capacity under operator-set limits.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Budget {
    #[serde(with = "rust_decimal::serde::float")]
    pub daily_limit: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub daily_used: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub daily_remaining: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub monthly_limit: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub monthly_used: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub monthly_remaining: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub per_tx_limit: Decimal,
}

/// Paginated list of transactions.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransactionList {
    pub items: Vec<Transaction>,
    pub total: u64,
    pub page: u32,
    pub per_page: u32,
    pub has_more: bool,
}
