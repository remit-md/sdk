use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

/// EVM chain IDs supported by remit.md.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(transparent)]
pub struct ChainId(pub u64);

impl ChainId {
    /// Base mainnet
    pub const BASE: ChainId = ChainId(8453);
    /// Base Sepolia testnet
    pub const BASE_SEPOLIA: ChainId = ChainId(84532);
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
    Active,
    Completed,
    Released,
    Cancelled,
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

/// ERC-2612 permit signature for gasless USDC approvals.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PermitSignature {
    pub value: u64,
    pub deadline: u64,
    pub v: u8,
    pub r: String,
    pub s: String,
}

/// On-chain contract addresses for the current deployment.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContractAddresses {
    pub chain_id: u64,
    pub usdc: String,
    pub router: String,
    pub escrow: String,
    pub tab: String,
    pub stream: String,
    pub bounty: String,
    pub deposit: String,
    pub fee_calculator: String,
    pub key_registry: String,
    #[serde(default)]
    pub relayer: Option<String>,
}

/// Result of a testnet mint operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MintResponse {
    pub tx_hash: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub balance: Decimal,
}

/// Chat-style message shown on a fund/withdraw page.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LinkMessage {
    /// "agent" or "system"
    pub role: String,
    /// Message text
    pub text: String,
}

/// One-time operator link for funding or withdrawing a wallet.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LinkResponse {
    pub url: String,
    pub token: String,
    pub expires_at: String,
    pub wallet_address: String,
}

// ─── Core types ──────────────────────────────────────────────────────────────

/// Result of any payment operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Transaction {
    /// Payment / invoice ID.  The server may return this as `invoice_id`.
    #[serde(default, alias = "invoice_id")]
    pub id: String,
    pub tx_hash: String,
    #[serde(default)]
    pub from: String,
    #[serde(default)]
    pub to: String,
    #[serde(default, with = "rust_decimal::serde::float")]
    pub amount: Decimal,
    #[serde(default, with = "rust_decimal::serde::float")]
    pub fee: Decimal,
    #[serde(default)]
    pub memo: String,
    #[serde(default)]
    pub chain_id: ChainId,
    #[serde(default)]
    pub block_number: u64,
    #[serde(default)]
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
    /// Wallet address.  The server may return this as `wallet`.
    #[serde(default, alias = "wallet")]
    pub address: String,
    /// Score from 0 (no history) to 1000 (perfect record).
    #[serde(default)]
    pub score: u32,
    #[serde(default, with = "rust_decimal::serde::float")]
    pub total_paid: Decimal,
    #[serde(default, with = "rust_decimal::serde::float")]
    pub total_received: Decimal,
    #[serde(default)]
    pub transaction_count: u64,
    #[serde(default)]
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
    /// Escrow identifier (server returns this as `invoice_id`).
    #[serde(alias = "invoice_id")]
    pub id: String,
    #[serde(default)]
    pub chain: String,
    #[serde(default)]
    pub tx_hash: String,
    pub payer: String,
    pub payee: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub amount: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub fee: Decimal,
    pub status: EscrowStatus,
    #[serde(default)]
    pub memo: String,
    #[serde(default)]
    pub claim_started: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub milestones: Vec<Milestone>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub splits: Vec<Split>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub created_at: DateTime<Utc>,
}

/// Off-chain payment channel for batched micro-payments.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tab {
    pub id: String,
    #[serde(default)]
    pub chain: String,
    #[serde(default, alias = "opener")]
    pub payer: String,
    #[serde(alias = "counterpart")]
    pub provider: String,
    #[serde(with = "rust_decimal::serde::float", alias = "limit")]
    pub limit_amount: Decimal,
    #[serde(default, with = "rust_decimal::serde::float")]
    pub per_unit: Decimal,
    #[serde(default, with = "rust_decimal::serde::float")]
    pub used: Decimal,
    #[serde(default, with = "rust_decimal::serde::float")]
    pub remaining: Decimal,
    pub status: TabStatus,
    #[serde(default)]
    pub expiry: u64,
    #[serde(default)]
    pub tx_hash: String,
    pub created_at: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub closes_at: Option<DateTime<Utc>>,
}

/// A single debit against a Tab (legacy).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TabDebit {
    pub tab_id: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub amount: Decimal,
    #[serde(default)]
    pub memo: String,
    #[serde(default)]
    pub sequence: u64,
    #[serde(default)]
    pub signature: String,
}

/// A charge against a Tab (on-chain signed by provider).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TabCharge {
    pub id: i64,
    pub tab_id: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub amount: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub cumulative: Decimal,
    pub call_count: u32,
    pub provider_sig: String,
    pub charged_at: DateTime<Utc>,
}

/// A bounty submission from a submitter.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BountySubmission {
    pub id: i64,
    pub bounty_id: String,
    pub submitter: String,
    pub evidence_hash: String,
    pub status: String,
    pub submitted_at: DateTime<Utc>,
}

/// Time-based payment stream (pay-per-second).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Stream {
    pub id: String,
    #[serde(default)]
    pub chain: String,
    #[serde(default, alias = "sender")]
    pub payer: String,
    pub payee: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub rate_per_second: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub max_total: Decimal,
    #[serde(default, with = "rust_decimal::serde::float")]
    pub withdrawn: Decimal,
    pub status: StreamStatus,
    #[serde(default)]
    pub started_at: DateTime<Utc>,
    #[serde(default)]
    pub tx_hash: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ends_at: Option<DateTime<Utc>>,
}

/// A task with a USDC reward for completion.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Bounty {
    pub id: String,
    #[serde(default)]
    pub chain: String,
    pub poster: String,
    #[serde(with = "rust_decimal::serde::float", alias = "award")]
    pub amount: Decimal,
    #[serde(alias = "description")]
    pub task_description: String,
    pub status: BountyStatus,
    #[serde(default)]
    pub deadline: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_attempts: Option<u32>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub winner: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub tx_hash: String,
    pub created_at: DateTime<Utc>,
}

/// Security deposit held as collateral.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Deposit {
    pub id: String,
    #[serde(default)]
    pub chain: String,
    pub depositor: String,
    #[serde(alias = "beneficiary")]
    pub provider: String,
    #[serde(with = "rust_decimal::serde::float")]
    pub amount: Decimal,
    pub status: DepositStatus,
    #[serde(default)]
    pub expiry: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub tx_hash: String,
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

/// A registered webhook endpoint.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Webhook {
    pub id: String,
    pub wallet: String,
    pub url: String,
    pub events: Vec<String>,
    #[serde(default)]
    pub chains: Vec<String>,
    pub active: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
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
