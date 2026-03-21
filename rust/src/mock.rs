use async_trait::async_trait;
use chrono::Utc;
use rust_decimal::Decimal;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use uuid::Uuid;

use crate::error::{codes, remit_err, RemitError};
use crate::http::Transport;
use crate::models::*;
use crate::signer::Signer;
use crate::wallet::Wallet;

const MOCK_WALLET: &str = "0xMockWallet0000000000000000000000000001";

/// In-memory mock for testing agents that use remit.md.
///
/// Zero network, zero latency, deterministic — the ideal test double.
/// Backed by `Arc<Mutex<>>` so it's safe to share across async tasks.
///
/// # Example
///
/// ```rust
/// use remitmd::MockRemit;
/// use rust_decimal_macros::dec;
///
/// #[tokio::test]
/// async fn agent_pays_correctly() {
///     let mock = MockRemit::new();
///     let wallet = mock.wallet();
///
///     wallet.pay("0xRecipient0000000000000000000000000000001", dec!(1.50)).await.unwrap();
///
///     assert!(mock.was_paid("0xRecipient0000000000000000000000000000001", dec!(1.50)).await);
///     assert_eq!(mock.total_paid_to("0xRecipient0000000000000000000000000000001").await, dec!(1.50));
/// }
/// ```
#[derive(Clone)]
pub struct MockRemit {
    state: Arc<Mutex<MockState>>,
}

struct PendingInvoice {
    payee: String,
    amount: Decimal,
    memo: String,
}

struct MockState {
    balance: Decimal,
    transactions: Vec<Transaction>,
    escrows: HashMap<String, Escrow>,
    pending_invoices: HashMap<String, PendingInvoice>,
    tabs: HashMap<String, Tab>,
    streams: HashMap<String, Stream>,
    bounties: HashMap<String, Bounty>,
    deposits: HashMap<String, Deposit>,
}

impl MockState {
    fn new(balance: Decimal) -> Self {
        Self {
            balance,
            transactions: Vec::new(),
            escrows: HashMap::new(),
            pending_invoices: HashMap::new(),
            tabs: HashMap::new(),
            streams: HashMap::new(),
            bounties: HashMap::new(),
            deposits: HashMap::new(),
        }
    }
}

impl MockRemit {
    /// Create a `MockRemit` with a default starting balance of 10,000 USDC.
    pub fn new() -> Self {
        Self::with_balance(Decimal::new(10_000, 0))
    }

    /// Create a `MockRemit` with a custom starting balance.
    pub fn with_balance(balance: Decimal) -> Self {
        Self {
            state: Arc::new(Mutex::new(MockState::new(balance))),
        }
    }

    /// Return a `Wallet` backed by this mock. No private key required.
    pub fn wallet(&self) -> Wallet {
        // Use Anvil test key #0 for mock permit signing.
        let signer = Arc::new(MockSigner);
        Wallet {
            transport: Arc::new(MockTransport {
                state: self.state.clone(),
            }),
            address: MOCK_WALLET.to_string(),
            chain_id: ChainId::BASE_SEPOLIA,
            chain: "base".to_string(),
            chain_key: "base-sepolia".to_string(),
            contracts_cache: Mutex::new(None),
            rpc_url: "http://127.0.0.1:8545".to_string(),
            signer,
        }
    }

    /// Reset all state. Call between test cases to prevent pollution.
    pub async fn reset(&self) {
        let mut s = self.state.lock().await;
        *s = MockState::new(Decimal::new(10_000, 0));
    }

    /// Override the simulated USDC balance.
    pub async fn set_balance(&self, amount: Decimal) {
        self.state.lock().await.balance = amount;
    }

    /// Return all transactions recorded by this mock.
    pub async fn transactions(&self) -> Vec<Transaction> {
        self.state.lock().await.transactions.clone()
    }

    /// Return the number of transactions recorded.
    pub async fn transaction_count(&self) -> usize {
        self.state.lock().await.transactions.len()
    }

    /// Return true if a payment of exactly `amount` USDC was sent to `recipient`.
    pub async fn was_paid(&self, recipient: &str, amount: Decimal) -> bool {
        let s = self.state.lock().await;
        s.transactions
            .iter()
            .any(|tx| tx.to.to_lowercase() == recipient.to_lowercase() && tx.amount == amount)
    }

    /// Return the sum of all USDC sent to `recipient`.
    pub async fn total_paid_to(&self, recipient: &str) -> Decimal {
        let s = self.state.lock().await;
        s.transactions
            .iter()
            .filter(|tx| tx.to.to_lowercase() == recipient.to_lowercase())
            .map(|tx| tx.amount)
            .fold(Decimal::ZERO, |acc, a| acc + a)
    }

    /// Return the current mock balance.
    pub async fn balance(&self) -> Decimal {
        self.state.lock().await.balance
    }
}

impl Default for MockRemit {
    fn default() -> Self {
        Self::new()
    }
}

// ─── MockSigner ──────────────────────────────────────────────────────────────

/// A no-op signer for mock wallets. Returns a dummy 65-byte signature.
struct MockSigner;

impl Signer for MockSigner {
    fn sign(&self, _digest: &[u8; 32]) -> Result<Vec<u8>, RemitError> {
        Ok(vec![0u8; 65])
    }

    fn address(&self) -> &str {
        MOCK_WALLET
    }
}

// ─── MockTransport ────────────────────────────────────────────────────────────

struct MockTransport {
    state: Arc<Mutex<MockState>>,
}

#[async_trait]
impl Transport for MockTransport {
    async fn post(&self, path: &str, body: Option<Value>) -> Result<Value, RemitError> {
        self.dispatch("POST", path, body).await
    }

    async fn get(&self, path: &str) -> Result<Value, RemitError> {
        self.dispatch("GET", path, None).await
    }
}

impl MockTransport {
    async fn dispatch(
        &self,
        method: &str,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, RemitError> {
        let b = body.unwrap_or(Value::Null);

        match (method, path) {
            // ─── Balance ──────────────────────────────────────────────────
            ("GET", "/api/v1/wallet/balance") => {
                let s = self.state.lock().await;
                Ok(json!({
                    "usdc": s.balance,
                    "address": "0xMockWallet0000000000000000000000000001",
                    "chain_id": 84532u64,
                    "updated_at": Utc::now(),
                }))
            }

            // ─── Direct payment ───────────────────────────────────────────
            ("POST", "/api/v1/payments/direct") => {
                let to = str_field(&b, "to")?;
                let amount = decimal_field(&b, "amount")?;
                let memo = b["task"].as_str().unwrap_or("").to_string();

                let mut s = self.state.lock().await;
                check_balance(s.balance, amount)?;
                s.balance -= amount;

                let tx = Transaction {
                    id: new_id("tx"),
                    tx_hash: format!("0x{}", mock_hash()),
                    from: "0xMockWallet0000000000000000000000000001".to_string(),
                    to,
                    amount,
                    fee: Decimal::new(1, 3),
                    memo,
                    chain_id: ChainId::BASE_SEPOLIA,
                    block_number: 0,
                    created_at: Utc::now(),
                };
                s.transactions.push(tx.clone());
                Ok(serde_json::to_value(&tx).unwrap())
            }

            // ─── Invoice create (step 1 of escrow) ────────────────────────
            ("POST", "/api/v1/invoices") => {
                let id = str_field(&b, "id")?;
                let payee = b["to_agent"].as_str().unwrap_or("").to_string();
                let amount = decimal_field(&b, "amount")?;
                let memo = b["task"].as_str().unwrap_or("").to_string();
                let mut s = self.state.lock().await;
                s.pending_invoices.insert(
                    id.clone(),
                    PendingInvoice {
                        payee,
                        amount,
                        memo,
                    },
                );
                Ok(json!({ "id": id, "status": "pending" }))
            }

            // ─── Escrow create (step 2: fund with invoice_id) ────────────
            ("POST", "/api/v1/escrows") => {
                let invoice_id = str_field(&b, "invoice_id")?;
                let mut s = self.state.lock().await;
                let inv = s.pending_invoices.remove(&invoice_id).ok_or_else(|| {
                    remit_err(codes::ESCROW_NOT_FOUND, "invoice not found in mock")
                })?;
                check_balance(s.balance, inv.amount)?;
                s.balance -= inv.amount;

                let escrow = Escrow {
                    id: invoice_id,
                    chain: "base-sepolia".to_string(),
                    tx_hash: format!("0x{}", mock_hash()),
                    payer: MOCK_WALLET.to_string(),
                    payee: inv.payee,
                    amount: inv.amount,
                    fee: Decimal::new(1, 3),
                    status: EscrowStatus::Funded,
                    memo: inv.memo,
                    claim_started: false,
                    milestones: vec![],
                    splits: vec![],
                    expires_at: None,
                    created_at: Utc::now(),
                };
                s.escrows.insert(escrow.id.clone(), escrow.clone());
                Ok(serde_json::to_value(&escrow).unwrap())
            }

            // ─── Escrow claim-start ──────────────────────────────────────
            (method, path) if method == "POST" && path.ends_with("/claim-start") => {
                let escrow_id = extract_id(path, "/api/v1/escrows/", "/claim-start");
                let mut s = self.state.lock().await;
                let escrow = s.escrows.get_mut(escrow_id).ok_or_else(|| {
                    remit_err(
                        codes::ESCROW_NOT_FOUND,
                        format!("escrow {escrow_id:?} not found"),
                    )
                })?;
                escrow.claim_started = true;
                Ok(serde_json::to_value(&*escrow).unwrap())
            }

            // ─── Escrow release ───────────────────────────────────────────
            (method, path) if method == "POST" && path.ends_with("/release") => {
                let escrow_id = extract_id(path, "/api/v1/escrows/", "/release");
                let mut s = self.state.lock().await;
                let escrow = s.escrows.get_mut(escrow_id).ok_or_else(|| {
                    remit_err(
                        codes::ESCROW_NOT_FOUND,
                        format!("escrow {escrow_id:?} not found"),
                    )
                })?;
                escrow.status = EscrowStatus::Released;
                Ok(serde_json::to_value(&*escrow).unwrap())
            }

            // ─── Escrow cancel ────────────────────────────────────────────
            (method, path) if method == "POST" && path.ends_with("/cancel") => {
                let escrow_id = extract_id(path, "/api/v1/escrows/", "/cancel");
                let mut s = self.state.lock().await;
                let escrow = s.escrows.get_mut(escrow_id).ok_or_else(|| {
                    remit_err(
                        codes::ESCROW_NOT_FOUND,
                        format!("escrow {escrow_id:?} not found"),
                    )
                })?;
                escrow.status = EscrowStatus::Cancelled;
                let amount = escrow.amount;
                let result = serde_json::to_value(&*escrow).unwrap();
                s.balance += amount; // refund to payer
                Ok(result)
            }

            // ─── Escrow get ───────────────────────────────────────────────
            ("GET", path) if path.starts_with("/api/v1/escrows/") => {
                let escrow_id = path.trim_start_matches("/api/v1/escrows/");
                let s = self.state.lock().await;
                let escrow = s.escrows.get(escrow_id).ok_or_else(|| {
                    remit_err(
                        codes::ESCROW_NOT_FOUND,
                        format!("escrow {escrow_id:?} not found"),
                    )
                })?;
                Ok(serde_json::to_value(escrow).unwrap())
            }

            // ─── Tab ──────────────────────────────────────────────────────
            ("POST", "/api/v1/tabs") => {
                let provider = b["provider"]
                    .as_str()
                    .or_else(|| b["counterpart"].as_str())
                    .unwrap_or("")
                    .to_string();
                let limit = b["limit_amount"]
                    .as_f64()
                    .or_else(|| {
                        decimal_field(&b, "limit")
                            .ok()
                            .map(|d| d.to_string().parse::<f64>().unwrap_or(0.0))
                    })
                    .unwrap_or(0.0);
                let limit = Decimal::from_str_exact(&format!("{limit}")).unwrap_or_default();
                let per_unit = b["per_unit"].as_f64().unwrap_or(0.0);
                let per_unit = Decimal::from_str_exact(&format!("{per_unit}")).unwrap_or_default();

                let tab = Tab {
                    id: new_id("tab"),
                    chain: "base-sepolia".to_string(),
                    payer: "0xMockWallet0000000000000000000000000001".to_string(),
                    provider,
                    limit_amount: limit,
                    per_unit,
                    used: Decimal::ZERO,
                    remaining: limit,
                    status: TabStatus::Open,
                    expiry: 0,
                    tx_hash: format!("0x{}", mock_hash()),
                    created_at: Utc::now(),
                    closes_at: None,
                };
                let mut s = self.state.lock().await;
                s.tabs.insert(tab.id.clone(), tab.clone());
                Ok(serde_json::to_value(&tab).unwrap())
            }

            // ─── Tab close ────────────────────────────────────────────────
            (method, path)
                if method == "POST" && path.ends_with("/close") && path.contains("/tabs/") =>
            {
                let tab_id = extract_id(path, "/api/v1/tabs/", "/close");
                let mut s = self.state.lock().await;
                let tab = s.tabs.get_mut(tab_id).ok_or_else(|| {
                    remit_err(codes::TAB_NOT_FOUND, format!("tab {tab_id:?} not found"))
                })?;
                tab.status = TabStatus::Closed;
                Ok(serde_json::to_value(&*tab).unwrap())
            }

            // ─── Stream ───────────────────────────────────────────────────
            ("POST", "/api/v1/streams") => {
                let payee = b["payee"]
                    .as_str()
                    .or_else(|| b["recipient"].as_str())
                    .unwrap_or("")
                    .to_string();
                let rate_per_second = b["rate_per_second"]
                    .as_f64()
                    .or_else(|| {
                        decimal_field(&b, "rate_per_sec")
                            .ok()
                            .map(|d| d.to_string().parse::<f64>().unwrap_or(0.0))
                    })
                    .unwrap_or(0.0);
                let rate_per_second =
                    Decimal::from_str_exact(&format!("{rate_per_second}")).unwrap_or_default();
                let max_total = b["max_total"]
                    .as_f64()
                    .or_else(|| {
                        decimal_field(&b, "deposit")
                            .ok()
                            .map(|d| d.to_string().parse::<f64>().unwrap_or(0.0))
                    })
                    .unwrap_or(0.0);
                let max_total =
                    Decimal::from_str_exact(&format!("{max_total}")).unwrap_or_default();

                let mut s = self.state.lock().await;
                check_balance(s.balance, max_total)?;
                s.balance -= max_total;

                let stream = Stream {
                    id: new_id("str"),
                    chain: "base-sepolia".to_string(),
                    payer: "0xMockWallet0000000000000000000000000001".to_string(),
                    payee,
                    rate_per_second,
                    max_total,
                    withdrawn: Decimal::ZERO,
                    status: StreamStatus::Active,
                    started_at: Utc::now(),
                    tx_hash: format!("0x{}", mock_hash()),
                    ends_at: None,
                };
                s.streams.insert(stream.id.clone(), stream.clone());
                Ok(serde_json::to_value(&stream).unwrap())
            }

            // ─── Bounty ───────────────────────────────────────────────────
            ("POST", "/api/v1/bounties") => {
                let amount = b["amount"]
                    .as_f64()
                    .or_else(|| {
                        decimal_field(&b, "award")
                            .ok()
                            .map(|d| d.to_string().parse::<f64>().unwrap_or(0.0))
                    })
                    .unwrap_or(0.0);
                let amount = Decimal::from_str_exact(&format!("{amount}")).unwrap_or_default();
                let task_description = b["task_description"]
                    .as_str()
                    .or_else(|| b["description"].as_str())
                    .unwrap_or("")
                    .to_string();
                let deadline = b["deadline"].as_u64().unwrap_or(0);

                let mut s = self.state.lock().await;
                check_balance(s.balance, amount)?;
                s.balance -= amount;

                let bounty = Bounty {
                    id: new_id("bnt"),
                    chain: "base-sepolia".to_string(),
                    poster: "0xMockWallet0000000000000000000000000001".to_string(),
                    amount,
                    task_description,
                    status: BountyStatus::Open,
                    deadline,
                    max_attempts: None,
                    winner: String::new(),
                    expires_at: None,
                    tx_hash: format!("0x{}", mock_hash()),
                    created_at: Utc::now(),
                };
                s.bounties.insert(bounty.id.clone(), bounty.clone());
                Ok(serde_json::to_value(&bounty).unwrap())
            }

            // ─── Bounty award ─────────────────────────────────────────────
            (method, path)
                if method == "POST" && path.ends_with("/award") && path.contains("/bounties/") =>
            {
                let bounty_id = extract_id(path, "/api/v1/bounties/", "/award");

                let mut s = self.state.lock().await;
                let bounty = s.bounties.get_mut(bounty_id).ok_or_else(|| {
                    remit_err(
                        codes::BOUNTY_NOT_FOUND,
                        format!("bounty {bounty_id:?} not found"),
                    )
                })?;
                bounty.status = BountyStatus::Awarded;
                Ok(serde_json::to_value(&*bounty).unwrap())
            }

            // ─── Deposit ──────────────────────────────────────────────────
            ("POST", "/api/v1/deposits") => {
                let provider = b["provider"]
                    .as_str()
                    .or_else(|| b["beneficiary"].as_str())
                    .unwrap_or("")
                    .to_string();
                let amount = b["amount"]
                    .as_f64()
                    .map(|f| Decimal::from_str_exact(&format!("{f}")).unwrap_or_default())
                    .or_else(|| decimal_field(&b, "amount").ok())
                    .unwrap_or_default();
                let expiry = b["expiry"].as_u64().unwrap_or(0);

                let mut s = self.state.lock().await;
                check_balance(s.balance, amount)?;
                s.balance -= amount;

                let deposit = Deposit {
                    id: new_id("dep"),
                    chain: "base-sepolia".to_string(),
                    depositor: "0xMockWallet0000000000000000000000000001".to_string(),
                    provider,
                    amount,
                    status: DepositStatus::Locked,
                    expiry,
                    expires_at: None,
                    tx_hash: format!("0x{}", mock_hash()),
                    created_at: Utc::now(),
                };
                s.deposits.insert(deposit.id.clone(), deposit.clone());
                Ok(serde_json::to_value(&deposit).unwrap())
            }

            // ─── Reputation ───────────────────────────────────────────────
            ("GET", path) if path.starts_with("/api/v1/reputation/") => {
                let address = path.trim_start_matches("/api/v1/reputation/");
                Ok(json!({
                    "address": address,
                    "score": 750u32,
                    "total_paid": "1000.0",
                    "total_received": "500.0",
                    "transaction_count": 42u64,
                    "member_since": Utc::now(),
                }))
            }

            // ─── Spending summary ─────────────────────────────────────────
            ("GET", path) if path.starts_with("/api/v1/wallet/spending") => {
                let s = self.state.lock().await;
                let total: Decimal = s.transactions.iter().map(|tx| tx.amount).sum();
                let count = s.transactions.len() as u64;
                Ok(json!({
                    "address": "0xMockWallet0000000000000000000000000001",
                    "period": "month",
                    "total_spent": total,
                    "total_fees": Decimal::new(1, 3) * Decimal::new(count as i64, 0),
                    "tx_count": count,
                    "top_recipients": [],
                }))
            }

            // ─── Budget ───────────────────────────────────────────────────
            ("GET", "/api/v1/wallet/budget") => Ok(json!({
                "daily_limit": "10000.0",
                "daily_used": "0.0",
                "daily_remaining": "10000.0",
                "monthly_limit": "100000.0",
                "monthly_used": "0.0",
                "monthly_remaining": "100000.0",
                "per_tx_limit": "1000.0",
            })),

            // ─── History ──────────────────────────────────────────────────
            ("GET", path) if path.starts_with("/api/v1/wallet/history") => {
                let s = self.state.lock().await;
                let total = s.transactions.len() as u64;
                Ok(json!({
                    "items": s.transactions,
                    "total": total,
                    "page": 1u32,
                    "per_page": 50u32,
                    "has_more": false,
                }))
            }

            // ─── Intents ──────────────────────────────────────────────────
            ("POST", "/api/v1/intents") => {
                let to = str_field(&b, "to")?;
                let amount = decimal_field(&b, "amount")?;
                let payment_type = b["type"].as_str().unwrap_or("direct").to_string();
                Ok(json!({
                    "id": new_id("int"),
                    "from": "0xMockWallet0000000000000000000000000001",
                    "to": to,
                    "amount": amount.to_string(),
                    "type": payment_type,
                    "expires_at": Utc::now(),
                    "created_at": Utc::now(),
                }))
            }

            // ─── Tab debit ────────────────────────────────────────────────
            (method, path) if method == "POST" && path.ends_with("/debit") => {
                let amount = decimal_field(&b, "amount")?;
                let memo = b["memo"].as_str().unwrap_or("").to_string();
                let tab_id = extract_id(path, "/api/v1/tabs/", "/debit");

                let mut s = self.state.lock().await;
                let tab = s.tabs.get_mut(tab_id).ok_or_else(|| {
                    remit_err(codes::TAB_NOT_FOUND, format!("tab {tab_id:?} not found"))
                })?;
                tab.used += amount;
                tab.remaining -= amount;

                Ok(json!({
                    "tab_id": tab_id,
                    "amount": amount.to_string(),
                    "memo": memo,
                    "sequence": 1u64,
                    "signature": "0x00",
                }))
            }

            // ─── Stream close ─────────────────────────────────────────────
            (method, path)
                if method == "POST" && path.contains("/streams/") && path.ends_with("/close") =>
            {
                let stream_id = extract_id(path, "/api/v1/streams/", "/close");
                let mut s = self.state.lock().await;
                let stream = s.streams.get_mut(stream_id).ok_or_else(|| {
                    remit_err(
                        codes::STREAM_NOT_FOUND,
                        format!("stream {stream_id:?} not found"),
                    )
                })?;
                stream.status = StreamStatus::Ended;
                Ok(serde_json::to_value(&*stream).unwrap())
            }

            // ─── Stream withdraw ──────────────────────────────────────────
            (method, path) if method == "POST" && path.ends_with("/withdraw") => {
                let stream_id = extract_id(path, "/api/v1/streams/", "/withdraw");
                let s = self.state.lock().await;
                let stream = s.streams.get(stream_id).ok_or_else(|| {
                    remit_err(
                        codes::STREAM_NOT_FOUND,
                        format!("stream {stream_id:?} not found"),
                    )
                })?;
                let tx = Transaction {
                    id: new_id("tx"),
                    tx_hash: format!("0x{}", mock_hash()),
                    from: stream.payer.clone(),
                    to: stream.payee.clone(),
                    amount: stream.max_total,
                    fee: Decimal::ZERO,
                    memo: "stream withdraw".to_string(),
                    chain_id: ChainId::BASE_SEPOLIA,
                    block_number: 0,
                    created_at: Utc::now(),
                };
                Ok(serde_json::to_value(&tx).unwrap())
            }

            // ─── Contracts ─────────────────────────────────────────────────
            ("GET", "/api/v1/contracts") => Ok(json!({
                "chain_id": 84532u64,
                "usdc": "0x0000000000000000000000000000000000000001",
                "router": "0x0000000000000000000000000000000000000002",
                "escrow": "0x0000000000000000000000000000000000000003",
                "tab": "0x0000000000000000000000000000000000000004",
                "stream": "0x0000000000000000000000000000000000000005",
                "bounty": "0x0000000000000000000000000000000000000006",
                "deposit": "0x0000000000000000000000000000000000000007",
                "fee_calculator": "0x0000000000000000000000000000000000000008",
                "key_registry": "0x0000000000000000000000000000000000000009",
                "arbitration": "0x000000000000000000000000000000000000000a",
            })),

            // ─── Mint ─────────────────────────────────────────────────────
            ("POST", "/api/v1/mint") => {
                let amount = b["amount"].as_f64().unwrap_or(0.0);
                let mut s = self.state.lock().await;
                s.balance += Decimal::from_str_exact(&format!("{amount}")).unwrap_or_default();
                Ok(json!({
                    "tx_hash": format!("0x{}", mock_hash()),
                    "balance": s.balance,
                }))
            }

            // ─── Catch-all: return empty success ──────────────────────────
            _ => Ok(Value::Null),
        }
    }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn new_id(prefix: &str) -> String {
    format!("{}_{}", prefix, &Uuid::new_v4().to_string()[..8])
}

fn mock_hash() -> String {
    Uuid::new_v4().to_string().replace('-', "") + &Uuid::new_v4().to_string().replace('-', "")
}

fn str_field(v: &Value, key: &str) -> Result<String, RemitError> {
    v[key]
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| remit_err(codes::SERVER_ERROR, format!("missing field: {key}")))
}

fn decimal_field(v: &Value, key: &str) -> Result<Decimal, RemitError> {
    let val = &v[key];
    // Accept both string ("1.50") and number (1.50) representations.
    if let Some(s) = val.as_str() {
        return Decimal::from_str_exact(s).map_err(|_| {
            remit_err(
                codes::INVALID_AMOUNT,
                format!("invalid decimal in field {key}: {s}"),
            )
        });
    }
    if let Some(n) = val.as_f64() {
        return Ok(Decimal::from_str_exact(&n.to_string()).unwrap_or_default());
    }
    Err(remit_err(
        codes::SERVER_ERROR,
        format!("missing field: {key}"),
    ))
}

fn check_balance(balance: Decimal, needed: Decimal) -> Result<(), RemitError> {
    if balance < needed {
        return Err(RemitError::new(
            codes::INSUFFICIENT_FUNDS,
            format!("insufficient balance: have {balance} USDC, need {needed} USDC"),
        )
        .with_context("balance", balance.to_string())
        .with_context("amount", needed.to_string()));
    }
    Ok(())
}

fn extract_id<'a>(path: &'a str, prefix: &str, suffix: &str) -> &'a str {
    let s = path.trim_start_matches(prefix);
    s.trim_end_matches(suffix)
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;

    const RECIPIENT: &str = "0x0000000000000000000000000000000000000001";
    const PAYEE: &str = "0x0000000000000000000000000000000000000002";

    #[tokio::test]
    async fn pay_deducts_balance_and_records_transaction() {
        let mock = MockRemit::new();
        let wallet = mock.wallet();

        let tx = wallet.pay(RECIPIENT, dec!(5.00)).await.unwrap();
        assert_eq!(tx.amount, dec!(5.00));
        assert_eq!(tx.to, RECIPIENT);
        assert!(mock.was_paid(RECIPIENT, dec!(5.00)).await);
        assert_eq!(mock.balance().await, dec!(9995.00));
    }

    #[tokio::test]
    async fn pay_with_memo_records_memo() {
        let mock = MockRemit::new();
        let wallet = mock.wallet();
        let tx = wallet
            .pay_with_memo(RECIPIENT, dec!(1.00), "API call fee")
            .await
            .unwrap();
        assert_eq!(tx.memo, "API call fee");
    }

    #[tokio::test]
    async fn insufficient_funds_returns_error() {
        let mock = MockRemit::with_balance(dec!(0.50));
        let wallet = mock.wallet();
        let err = wallet.pay(RECIPIENT, dec!(1.00)).await.unwrap_err();
        assert_eq!(err.code, codes::INSUFFICIENT_FUNDS);
    }

    #[tokio::test]
    async fn total_paid_to_sums_multiple_payments() {
        let mock = MockRemit::new();
        let wallet = mock.wallet();

        wallet.pay(RECIPIENT, dec!(1.00)).await.unwrap();
        wallet.pay(RECIPIENT, dec!(2.50)).await.unwrap();
        wallet.pay(PAYEE, dec!(10.00)).await.unwrap();

        assert_eq!(mock.total_paid_to(RECIPIENT).await, dec!(3.50));
        assert_eq!(mock.total_paid_to(PAYEE).await, dec!(10.00));
        assert_eq!(mock.transaction_count().await, 3);
    }

    #[tokio::test]
    async fn escrow_lifecycle_funded_then_released() {
        let mock = MockRemit::new();
        let wallet = mock.wallet();

        let escrow = wallet.create_escrow(PAYEE, dec!(100.00)).await.unwrap();
        assert_eq!(escrow.status, EscrowStatus::Funded);
        assert_eq!(mock.balance().await, dec!(9900.00));

        let fetched = wallet.get_escrow(&escrow.id).await.unwrap();
        assert_eq!(fetched.id, escrow.id);

        let released = wallet.release_escrow(&escrow.id, None).await.unwrap();
        assert_eq!(released.payee, PAYEE);
        assert_eq!(released.amount, dec!(100.00));
        assert_eq!(released.status, EscrowStatus::Released);
    }

    #[tokio::test]
    async fn escrow_cancel_refunds_payer() {
        let mock = MockRemit::new();
        let wallet = mock.wallet();

        let escrow = wallet.create_escrow(PAYEE, dec!(50.00)).await.unwrap();
        assert_eq!(mock.balance().await, dec!(9950.00));

        wallet.cancel_escrow(&escrow.id).await.unwrap();
        assert_eq!(mock.balance().await, dec!(10000.00)); // refunded
    }

    #[tokio::test]
    async fn tab_lifecycle_open_and_close() {
        let mock = MockRemit::new();
        let wallet = mock.wallet();

        let tab = wallet
            .create_tab(PAYEE, dec!(10.00), dec!(0.10))
            .await
            .unwrap();
        assert_eq!(tab.status, TabStatus::Open);

        let closed = wallet.close_tab(&tab.id, 0.10, "0x00").await.unwrap();
        assert_eq!(closed.status, TabStatus::Closed);
    }

    #[tokio::test]
    async fn stream_creation_deducts_max_total() {
        let mock = MockRemit::new();
        let wallet = mock.wallet();

        let stream = wallet
            .create_stream(RECIPIENT, dec!(0.001), dec!(100.00))
            .await
            .unwrap();
        assert_eq!(stream.status, StreamStatus::Active);
        assert_eq!(mock.balance().await, dec!(9900.00));
    }

    #[tokio::test]
    async fn bounty_lifecycle_post_and_award() {
        let mock = MockRemit::new();
        let wallet = mock.wallet();

        let deadline = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 3600;
        let bounty = wallet
            .create_bounty(dec!(5.00), "find the cheapest API route", deadline)
            .await
            .unwrap();
        assert_eq!(bounty.status, BountyStatus::Open);

        let awarded = wallet.award_bounty(&bounty.id, 1).await.unwrap();
        assert_eq!(awarded.status, BountyStatus::Awarded);
    }

    #[tokio::test]
    async fn deposit_lock_deducts_balance() {
        let mock = MockRemit::new();
        let wallet = mock.wallet();

        let expiry = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 86400;
        let deposit = wallet
            .lock_deposit(PAYEE, dec!(20.00), expiry)
            .await
            .unwrap();
        assert_eq!(deposit.status, DepositStatus::Locked);
        assert_eq!(mock.balance().await, dec!(9980.00));
    }

    #[tokio::test]
    async fn reset_clears_all_state() {
        let mock = MockRemit::new();
        let wallet = mock.wallet();

        wallet.pay(RECIPIENT, dec!(100.00)).await.unwrap();
        assert_eq!(mock.transaction_count().await, 1);

        mock.reset().await;
        assert_eq!(mock.transaction_count().await, 0);
        assert_eq!(mock.balance().await, dec!(10000.00));
    }

    #[tokio::test]
    async fn balance_returns_current_usdc() {
        let mock = MockRemit::new();
        let wallet = mock.wallet();
        let bal = wallet.balance().await.unwrap();
        assert_eq!(bal.usdc, dec!(10000.00));
    }

    #[tokio::test]
    async fn reputation_returns_mock_data() {
        let mock = MockRemit::new();
        let wallet = mock.wallet();
        let rep = wallet.reputation(RECIPIENT).await.unwrap();
        assert_eq!(rep.score, 750);
    }

    #[tokio::test]
    async fn invalid_address_rejected_before_network() {
        let mock = MockRemit::new();
        let wallet = mock.wallet();
        let err = wallet.pay("not-an-address", dec!(1.00)).await.unwrap_err();
        assert_eq!(err.code, codes::INVALID_ADDRESS);
        assert!(err.message.contains("0x-prefixed"));
    }

    #[tokio::test]
    async fn amount_below_minimum_rejected() {
        let mock = MockRemit::new();
        let wallet = mock.wallet();
        let err = wallet.pay(RECIPIENT, dec!(0.0000001)).await.unwrap_err();
        assert_eq!(err.code, codes::INVALID_AMOUNT);
        assert!(err.message.contains("minimum"));
    }
}
