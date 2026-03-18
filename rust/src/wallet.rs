use rust_decimal::Decimal;
use serde_json::{json, Value};
use std::env;
use std::str::FromStr;
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::error::{codes, remit_err, remit_err_ctx, RemitError};
use crate::http::{chain_config, HttpTransport, Transport};
use crate::models::*;
use crate::signer::{PrivateKeySigner, Signer};

/// Primary remit.md client for AI agents that send and receive payments.
///
/// All payment operations are async methods on `Wallet`. Create a wallet with
/// a private key or from environment variables.
///
/// # Quick start
///
/// ```rust,no_run
/// use remitmd::Wallet;
/// use rust_decimal_macros::dec;
///
/// #[tokio::main]
/// async fn main() -> Result<(), Box<dyn std::error::Error>> {
///     let wallet = Wallet::from_env()?;
///     let tx = wallet.pay("0xRecipient...", dec!(1.50)).await?;
///     println!("paid: {} in tx {}", tx.amount, tx.tx_hash);
///     Ok(())
/// }
/// ```
///
/// # Testing
///
/// Use `MockRemit` for unit tests — zero network, deterministic:
///
/// ```rust
/// use remitmd::MockRemit;
/// use rust_decimal_macros::dec;
///
/// #[tokio::test]
/// async fn test_agent_pays() {
///     let mock = MockRemit::new();
///     let wallet = mock.wallet();
///     wallet.pay("0xRecipient0000000000000000000000000000001", dec!(5.00)).await.unwrap();
///     assert!(mock.was_paid("0xRecipient0000000000000000000000000000001", dec!(5.00)).await);
/// }
/// ```
pub struct Wallet {
    pub(crate) transport: Arc<dyn Transport>,
    pub(crate) address: String,
    pub(crate) chain_id: ChainId,
    pub(crate) chain: String,
    pub(crate) contracts_cache: Mutex<Option<ContractAddresses>>,
}

impl Wallet {
    /// Create a wallet from a hex-encoded private key.
    ///
    /// # Arguments
    /// - `private_key` — 32-byte private key as hex (with or without `0x` prefix)
    ///
    /// # Options
    /// - `.testnet()` — use testnet
    /// - `.base_url("http://localhost:3000")` — override API URL
    #[allow(clippy::new_ret_no_self)]
    pub fn new(private_key: &str) -> WalletBuilder<WithKey> {
        WalletBuilder {
            key_or_signer: WithKey(private_key.to_string()),
            chain: "base".to_string(),
            testnet: false,
            base_url: None,
            router_address: None,
        }
    }

    /// Create a wallet with a custom signer (e.g., KMS-backed).
    pub fn with_signer(signer: impl Signer + 'static) -> WalletBuilder<WithSigner> {
        WalletBuilder {
            key_or_signer: WithSigner(Arc::new(signer)),
            chain: "base".to_string(),
            testnet: false,
            base_url: None,
            router_address: None,
        }
    }

    /// Create a wallet from environment variables:
    /// - `REMITMD_KEY` — hex-encoded private key (required)
    /// - `REMITMD_CHAIN` — chain name (default: `"base"`)
    /// - `REMITMD_TESTNET` — `"1"`, `"true"`, or `"yes"` for testnet
    /// - `REMITMD_ROUTER_ADDRESS` — EIP-712 verifying contract address
    pub fn from_env() -> Result<Self, RemitError> {
        let key = env::var("REMITMD_KEY").map_err(|_| {
            remit_err_ctx(
                codes::UNAUTHORIZED,
                "REMITMD_KEY environment variable is not set. Set it to your hex-encoded private key.",
                "hint",
                "export REMITMD_KEY=0x...",
            )
        })?;

        let chain = env::var("REMITMD_CHAIN").unwrap_or_else(|_| "base".to_string());
        let testnet = matches!(
            env::var("REMITMD_TESTNET").as_deref(),
            Ok("1") | Ok("true") | Ok("yes")
        );
        let router_address = env::var("REMITMD_ROUTER_ADDRESS").unwrap_or_default();

        let mut builder = Self::new(&key).chain(&chain);
        if testnet {
            builder = builder.testnet();
        }
        if !router_address.is_empty() {
            builder = builder.router_address(&router_address);
        }
        builder.build()
    }

    /// Ethereum address of this wallet (checksummed `0x`-prefixed hex).
    pub fn address(&self) -> &str {
        &self.address
    }

    /// Chain ID this wallet is connected to.
    pub fn chain_id(&self) -> ChainId {
        self.chain_id
    }

    // ─── Internal helpers ────────────────────────────────────────────────────

    async fn get<T: serde::de::DeserializeOwned>(&self, path: &str) -> Result<T, RemitError> {
        let v = self.transport.get(path).await?;
        serde_json::from_value(v).map_err(|e| {
            remit_err(
                codes::SERVER_ERROR,
                format!("failed to deserialize response: {e}"),
            )
        })
    }

    async fn post<T: serde::de::DeserializeOwned>(
        &self,
        path: &str,
        body: Value,
    ) -> Result<T, RemitError> {
        let v = self.transport.post(path, Some(body)).await?;
        serde_json::from_value(v).map_err(|e| {
            remit_err(
                codes::SERVER_ERROR,
                format!("failed to deserialize response: {e}"),
            )
        })
    }
}

// ─── Payment methods ─────────────────────────────────────────────────────────

impl Wallet {
    /// Return the current USDC balance of this wallet.
    pub async fn balance(&self) -> Result<Balance, RemitError> {
        self.get("/api/v0/wallet/balance").await
    }

    /// Send a direct USDC payment.
    ///
    /// Direct payments are one-way transfers with no escrow or refund mechanism.
    /// For reversible payments, use `create_escrow`.
    ///
    /// # Arguments
    /// - `to` — recipient Ethereum address
    /// - `amount` — USDC amount (minimum: 0.000001, maximum: 1,000,000)
    ///
    /// # Example
    /// ```rust,ignore
    /// use rust_decimal_macros::dec;
    /// let tx = wallet.pay("0xAgent...", dec!(0.003)).await?;
    /// ```
    pub async fn pay(&self, to: &str, amount: Decimal) -> Result<Transaction, RemitError> {
        self.pay_with_memo(to, amount, "").await
    }

    /// Send a direct USDC payment with a permit for gasless approval.
    pub async fn pay_with_permit(
        &self,
        to: &str,
        amount: Decimal,
        permit: PermitSignature,
    ) -> Result<Transaction, RemitError> {
        self.pay_full(to, amount, "", Some(permit)).await
    }

    /// Send a direct USDC payment with an optional memo.
    pub async fn pay_with_memo(
        &self,
        to: &str,
        amount: Decimal,
        memo: &str,
    ) -> Result<Transaction, RemitError> {
        self.pay_full(to, amount, memo, None).await
    }

    /// Send a direct USDC payment with an optional memo and permit.
    pub async fn pay_full(
        &self,
        to: &str,
        amount: Decimal,
        memo: &str,
        permit: Option<PermitSignature>,
    ) -> Result<Transaction, RemitError> {
        validate_address(to)?;
        validate_amount(amount)?;
        let mut nb = [0u8; 16];
        getrandom::getrandom(&mut nb)
            .map_err(|_| remit_err(codes::SERVER_ERROR, "random generation failed"))?;
        let nonce = hex::encode(nb);
        let mut body = json!({
            "to": to,
            "amount": amount.to_string(),
            "task": memo,
            "chain": &self.chain,
            "nonce": nonce,
            "signature": "0x",
        });
        if let Some(p) = permit {
            body["permit"] = serde_json::to_value(p).unwrap();
        }
        self.post("/api/v0/payments/direct", body).await
    }

    /// Return paginated transaction history.
    ///
    /// # Arguments
    /// - `page` — 1-indexed page number (default: 1)
    /// - `per_page` — results per page (default: 20, max: 100)
    pub async fn history(&self, page: u32, per_page: u32) -> Result<TransactionList, RemitError> {
        let per_page = per_page.clamp(1, 100);
        let path = format!("/api/v0/wallet/history?page={page}&per_page={per_page}");
        self.get(&path).await
    }

    /// Return the on-chain reputation for any Ethereum address.
    pub async fn reputation(&self, address: &str) -> Result<Reputation, RemitError> {
        validate_address(address)?;
        self.get(&format!("/api/v0/reputation/{address}")).await
    }

    /// Return spending analytics for this wallet.
    ///
    /// # Arguments
    /// - `period` — `"day"`, `"week"`, `"month"`, or `"all"`
    pub async fn spending_summary(&self, period: &str) -> Result<SpendingSummary, RemitError> {
        self.get(&format!("/api/v0/wallet/spending?period={period}"))
            .await
    }

    /// Return the remaining spending budget under operator-set limits.
    pub async fn remaining_budget(&self) -> Result<Budget, RemitError> {
        self.get("/api/v0/wallet/budget").await
    }

    // ─── Escrow ──────────────────────────────────────────────────────────────

    /// Create and fund an escrow for work to be done.
    ///
    /// Funds are locked until the payer calls `release_escrow` or the escrow
    /// expires. Use for high-value tasks where delivery must be verified before
    /// payment.
    ///
    /// # Arguments
    /// - `payee` — the agent that will receive funds on release
    /// - `amount` — total USDC to lock
    pub async fn create_escrow(&self, payee: &str, amount: Decimal) -> Result<Escrow, RemitError> {
        self.create_escrow_full(payee, amount, "", &[], &[], None, None)
            .await
    }

    /// Create an escrow with a permit for gasless approval.
    pub async fn create_escrow_with_permit(
        &self,
        payee: &str,
        amount: Decimal,
        permit: PermitSignature,
    ) -> Result<Escrow, RemitError> {
        self.create_escrow_full(payee, amount, "", &[], &[], None, Some(permit))
            .await
    }

    /// Create an escrow with optional milestones, splits, and permit.
    ///
    /// Two-step flow: creates an invoice, then funds the escrow.
    #[allow(clippy::too_many_arguments)]
    pub async fn create_escrow_full(
        &self,
        payee: &str,
        amount: Decimal,
        memo: &str,
        _milestones: &[Milestone],
        _splits: &[Split],
        expires_in_secs: Option<u64>,
        permit: Option<PermitSignature>,
    ) -> Result<Escrow, RemitError> {
        validate_address(payee)?;
        validate_amount(amount)?;

        // Step 1: create the invoice.
        let mut nb = [0u8; 16];
        getrandom::getrandom(&mut nb)
            .map_err(|_| remit_err(codes::SERVER_ERROR, "random generation failed"))?;
        let invoice_id = hex::encode(nb);

        let mut inv_body = json!({
            "id": invoice_id,
            "chain": &self.chain,
            "from_agent": self.address().to_lowercase(),
            "to_agent": payee.to_lowercase(),
            "amount": amount.to_string().parse::<f64>().unwrap_or(0.0),
            "type": "escrow",
            "task": memo,
            "nonce": hex::encode(nb),
            "signature": "0x",
        });
        if let Some(secs) = expires_in_secs {
            inv_body["escrow_timeout"] = json!(secs);
        }
        // Discard response (server returns 201 with invoice data).
        let _: serde_json::Value = self.post("/api/v0/invoices", inv_body).await?;

        // Step 2: fund the escrow.
        let mut escrow_body = json!({ "invoice_id": invoice_id });
        if let Some(p) = permit {
            escrow_body["permit"] = serde_json::to_value(p).unwrap();
        }
        self.post("/api/v0/escrows", escrow_body).await
    }

    /// Signal that the payee has started work on an escrow.
    ///
    /// Must be called by the payee before the payer can release funds.
    pub async fn claim_start(&self, escrow_id: &str) -> Result<Escrow, RemitError> {
        self.post(
            &format!("/api/v0/escrows/{escrow_id}/claim-start"),
            json!({}),
        )
        .await
    }

    /// Release escrow funds to the payee.
    ///
    /// Optionally specify a `milestone_id` to release only one milestone.
    pub async fn release_escrow(
        &self,
        escrow_id: &str,
        milestone_id: Option<&str>,
    ) -> Result<Escrow, RemitError> {
        let mut body = json!({ "escrow_id": escrow_id });
        if let Some(mid) = milestone_id {
            body["milestone_id"] = json!(mid);
        }
        self.post(&format!("/api/v0/escrows/{escrow_id}/release"), body)
            .await
    }

    /// Cancel the escrow and return funds to the payer.
    pub async fn cancel_escrow(&self, escrow_id: &str) -> Result<Escrow, RemitError> {
        self.post(&format!("/api/v0/escrows/{escrow_id}/cancel"), json!({}))
            .await
    }

    /// Fetch the current state of an escrow.
    pub async fn get_escrow(&self, escrow_id: &str) -> Result<Escrow, RemitError> {
        self.get(&format!("/api/v0/escrows/{escrow_id}")).await
    }

    // ─── Tab ─────────────────────────────────────────────────────────────────

    /// Open a payment channel for batched micro-payments.
    ///
    /// Tabs are ideal for high-frequency low-value payments (e.g., per-token LLM
    /// billing, per-query data APIs). Debits are off-chain; settlement is on-chain.
    ///
    /// # Arguments
    /// - `counterpart` — the agent receiving payments
    /// - `limit` — maximum USDC pre-deposited into the channel
    pub async fn create_tab(&self, counterpart: &str, limit: Decimal) -> Result<Tab, RemitError> {
        self.create_tab_full(counterpart, limit, None, None).await
    }

    /// Open a tab with a permit for gasless approval.
    pub async fn create_tab_with_permit(
        &self,
        counterpart: &str,
        limit: Decimal,
        permit: PermitSignature,
    ) -> Result<Tab, RemitError> {
        self.create_tab_full(counterpart, limit, None, Some(permit))
            .await
    }

    /// Open a tab with a custom expiry.
    pub async fn create_tab_with_expiry(
        &self,
        counterpart: &str,
        limit: Decimal,
        expires_in_secs: u64,
    ) -> Result<Tab, RemitError> {
        self.create_tab_full(counterpart, limit, Some(expires_in_secs), None)
            .await
    }

    /// Open a tab with optional expiry and permit.
    pub async fn create_tab_full(
        &self,
        counterpart: &str,
        limit: Decimal,
        expires_in_secs: Option<u64>,
        permit: Option<PermitSignature>,
    ) -> Result<Tab, RemitError> {
        validate_address(counterpart)?;
        let mut body = json!({
            "chain": &self.chain,
            "counterpart": counterpart,
            "limit": limit.to_string(),
        });
        if let Some(exp) = expires_in_secs {
            body["expires_in_seconds"] = json!(exp);
        }
        if let Some(p) = permit {
            body["permit"] = serde_json::to_value(p).unwrap();
        }
        self.post("/api/v0/tabs", body).await
    }

    /// Debit a charge from an open tab (off-chain, signed).
    pub async fn debit_tab(
        &self,
        tab_id: &str,
        amount: Decimal,
        memo: &str,
    ) -> Result<TabDebit, RemitError> {
        validate_amount(amount)?;
        self.post(
            &format!("/api/v0/tabs/{tab_id}/debit"),
            json!({
                "tab_id": tab_id,
                "amount": amount.to_string(),
                "memo": memo,
            }),
        )
        .await
    }

    /// Close the tab and settle all charges on-chain.
    pub async fn settle_tab(&self, tab_id: &str) -> Result<Transaction, RemitError> {
        self.post(&format!("/api/v0/tabs/{tab_id}/settle"), json!({}))
            .await
    }

    // ─── Stream ──────────────────────────────────────────────────────────────

    /// Start a per-second USDC payment stream.
    ///
    /// Streams are ideal for subscription-style payments where the recipient
    /// provides ongoing value (compute time, uptime guarantees, etc.).
    ///
    /// # Arguments
    /// - `recipient` — the agent receiving the stream
    /// - `rate_per_sec` — USDC per second
    /// - `deposit` — total USDC pre-deposited (determines stream duration)
    pub async fn create_stream(
        &self,
        recipient: &str,
        rate_per_sec: Decimal,
        deposit: Decimal,
    ) -> Result<Stream, RemitError> {
        self.create_stream_with_permit(recipient, rate_per_sec, deposit, None)
            .await
    }

    /// Start a per-second USDC payment stream with an optional permit.
    pub async fn create_stream_with_permit(
        &self,
        recipient: &str,
        rate_per_sec: Decimal,
        deposit: Decimal,
        permit: Option<PermitSignature>,
    ) -> Result<Stream, RemitError> {
        validate_address(recipient)?;
        validate_amount(deposit)?;
        let mut body = json!({
            "chain": &self.chain,
            "recipient": recipient,
            "rate_per_sec": rate_per_sec.to_string(),
            "deposit": deposit.to_string(),
        });
        if let Some(p) = permit {
            body["permit"] = serde_json::to_value(p).unwrap();
        }
        self.post("/api/v0/streams", body).await
    }

    /// Withdraw all vested stream payments (called by the recipient).
    pub async fn withdraw_stream(&self, stream_id: &str) -> Result<Transaction, RemitError> {
        self.post(&format!("/api/v0/streams/{stream_id}/withdraw"), json!({}))
            .await
    }

    // ─── Bounty ──────────────────────────────────────────────────────────────

    /// Post a USDC bounty for task completion.
    ///
    /// Any agent can submit work; the poster awards the bounty to the winner.
    ///
    /// # Arguments
    /// - `award` — USDC prize for the winner
    /// - `description` — task description (agent-readable)
    pub async fn create_bounty(
        &self,
        award: Decimal,
        description: &str,
    ) -> Result<Bounty, RemitError> {
        validate_amount(award)?;
        self.post(
            "/api/v0/bounties",
            json!({
                "chain": &self.chain,
                "award": award.to_string(),
                "description": description,
            }),
        )
        .await
    }

    /// Create a bounty with a custom expiry.
    pub async fn create_bounty_with_expiry(
        &self,
        award: Decimal,
        description: &str,
        expires_in_secs: u64,
    ) -> Result<Bounty, RemitError> {
        validate_amount(award)?;
        self.post(
            "/api/v0/bounties",
            json!({
                "chain": &self.chain,
                "award": award.to_string(),
                "description": description,
                "expires_in_seconds": expires_in_secs,
            }),
        )
        .await
    }

    /// Award a bounty to the winner.
    pub async fn award_bounty(
        &self,
        bounty_id: &str,
        winner: &str,
    ) -> Result<Transaction, RemitError> {
        validate_address(winner)?;
        self.post(
            &format!("/api/v0/bounties/{bounty_id}/award"),
            json!({
                "bounty_id": bounty_id,
                "winner": winner,
            }),
        )
        .await
    }

    /// List bounties with optional filters.
    ///
    /// # Arguments
    /// - `status` — filter by status (open, claimed, awarded, expired)
    /// - `poster` — filter by poster wallet address
    /// - `submitter` — filter by submitter wallet address
    /// - `limit` — max results (default 20, max 100)
    pub async fn list_bounties(
        &self,
        status: Option<&str>,
        poster: Option<&str>,
        submitter: Option<&str>,
        limit: Option<u32>,
    ) -> Result<Vec<Bounty>, RemitError> {
        let mut params = vec![];
        if let Some(s) = status {
            params.push(format!("status={s}"));
        }
        if let Some(p) = poster {
            params.push(format!("poster={p}"));
        }
        if let Some(s) = submitter {
            params.push(format!("submitter={s}"));
        }
        if let Some(l) = limit {
            params.push(format!("limit={l}"));
        }
        let qs = if params.is_empty() {
            String::new()
        } else {
            format!("?{}", params.join("&"))
        };

        #[derive(serde::Deserialize)]
        struct Resp {
            data: Vec<Bounty>,
        }
        let resp: Resp = self.get(&format!("/api/v0/bounties{qs}")).await?;
        Ok(resp.data)
    }

    // ─── Deposit ─────────────────────────────────────────────────────────────

    /// Lock a security deposit with a beneficiary.
    ///
    /// The depositor's funds are locked until the beneficiary forfeits them,
    /// the depositor requests return (after the lock period), or the deposit expires.
    ///
    /// # Arguments
    /// - `beneficiary` — address that can forfeit the deposit
    /// - `amount` — USDC to lock
    /// - `expires_in_secs` — lock duration in seconds
    pub async fn lock_deposit(
        &self,
        beneficiary: &str,
        amount: Decimal,
        expires_in_secs: u64,
    ) -> Result<Deposit, RemitError> {
        validate_address(beneficiary)?;
        validate_amount(amount)?;
        self.post(
            "/api/v0/deposits",
            json!({
                "beneficiary": beneficiary,
                "amount": amount.to_string(),
                "expires_in_seconds": expires_in_secs,
            }),
        )
        .await
    }

    // ─── Intent negotiation ──────────────────────────────────────────────────

    /// Propose a payment intent for negotiation (agent-to-agent).
    pub async fn propose_intent(
        &self,
        to: &str,
        amount: Decimal,
        payment_type: &str,
    ) -> Result<Intent, RemitError> {
        validate_address(to)?;
        self.post(
            "/api/v0/intents",
            json!({
                "to": to,
                "amount": amount.to_string(),
                "type": payment_type,
            }),
        )
        .await
    }

    // ─── One-time operator links ──────────────────────────────────────────────

    // ─── Webhooks ────────────────────────────────────────────────────────────

    /// Register a webhook endpoint to receive event notifications.
    ///
    /// # Arguments
    /// - `url` — the HTTPS endpoint that will receive POST notifications
    /// - `events` — event types to subscribe to (e.g. `["payment.sent", "escrow.funded"]`)
    /// - `chains` — optional list of chain names to filter by (e.g. `["base"]`)
    pub async fn register_webhook(
        &self,
        url: &str,
        events: &[&str],
        chains: Option<&[&str]>,
    ) -> Result<Webhook, RemitError> {
        let mut body = json!({
            "url": url,
            "events": events,
        });
        if let Some(chains) = chains {
            body["chains"] = json!(chains);
        }
        self.post("/api/v0/webhooks", body).await
    }

    /// Generate a one-time URL for the operator to fund this wallet.
    pub async fn create_fund_link(&self) -> Result<LinkResponse, RemitError> {
        self.post("/api/v0/links/fund", json!({})).await
    }

    /// Generate a one-time URL for the operator to withdraw funds.
    pub async fn create_withdraw_link(&self) -> Result<LinkResponse, RemitError> {
        self.post("/api/v0/links/withdraw", json!({})).await
    }

    // ─── Contracts ──────────────────────────────────────────────────────────

    /// Return the on-chain contract addresses for the current deployment.
    ///
    /// Results are cached after the first call.
    pub async fn get_contracts(&self) -> Result<ContractAddresses, RemitError> {
        {
            let cache = self.contracts_cache.lock().await;
            if let Some(ref c) = *cache {
                return Ok(c.clone());
            }
        }
        let contracts: ContractAddresses = self.get("/api/v0/contracts").await?;
        {
            let mut cache = self.contracts_cache.lock().await;
            *cache = Some(contracts.clone());
        }
        Ok(contracts)
    }

    // ─── Mint (testnet only) ────────────────────────────────────────────────

    /// Mint testnet USDC to this wallet.
    ///
    /// Only available on testnet deployments. Production calls will return an error.
    ///
    /// # Arguments
    /// - `amount` — USDC amount to mint
    pub async fn mint(&self, amount: f64) -> Result<MintResponse, RemitError> {
        self.post(
            "/api/v0/mint",
            json!({
                "wallet": &self.address,
                "amount": amount,
            }),
        )
        .await
    }
}

// ─── WalletBuilder ────────────────────────────────────────────────────────────

/// Typestate for WalletBuilder: key-based construction.
pub struct WithKey(String);
/// Typestate for WalletBuilder: custom signer construction.
pub struct WithSigner(Arc<dyn Signer>);

/// Builder for `Wallet`. Use `Wallet::new(key)` or `Wallet::with_signer(signer)`.
pub struct WalletBuilder<S> {
    pub(crate) key_or_signer: S,
    pub(crate) chain: String,
    pub(crate) testnet: bool,
    pub(crate) base_url: Option<String>,
    pub(crate) router_address: Option<String>,
}

impl<S> WalletBuilder<S> {
    /// Set the target chain. Currently only `"base"` is supported.
    /// Default: `"base"`.
    pub fn chain(mut self, chain: &str) -> Self {
        self.chain = chain.to_string();
        self
    }

    /// Target the testnet version of the selected chain.
    pub fn testnet(mut self) -> Self {
        self.testnet = true;
        self
    }

    /// Override the API base URL. Useful for self-hosted deployments or local testing.
    pub fn base_url(mut self, url: &str) -> Self {
        self.base_url = Some(url.to_string());
        self
    }

    /// Set the EIP-712 verifying contract address (router). Required for production use.
    pub fn router_address(mut self, addr: &str) -> Self {
        self.router_address = Some(addr.to_string());
        self
    }
}

impl WalletBuilder<WithKey> {
    /// Build the `Wallet`, returning an error if the private key or chain is invalid.
    pub fn build(self) -> Result<Wallet, RemitError> {
        let signer = Arc::new(PrivateKeySigner::new(&self.key_or_signer.0)?);
        build_wallet(
            signer,
            &self.chain,
            self.testnet,
            self.base_url,
            self.router_address,
        )
    }
}

impl WalletBuilder<WithSigner> {
    /// Build the `Wallet` with the custom signer.
    pub fn build(self) -> Result<Wallet, RemitError> {
        build_wallet(
            self.key_or_signer.0,
            &self.chain,
            self.testnet,
            self.base_url,
            self.router_address,
        )
    }
}

fn build_wallet(
    signer: Arc<dyn Signer>,
    chain: &str,
    testnet: bool,
    base_url_override: Option<String>,
    router_address: Option<String>,
) -> Result<Wallet, RemitError> {
    let chain_key = if testnet {
        format!("{chain}-sepolia")
    } else {
        chain.to_string()
    };

    let cfg = chain_config(&chain_key).ok_or_else(|| {
        remit_err(
            codes::CHAIN_MISMATCH,
            format!(
                "unsupported chain: {chain:?}. Valid chains: base. For testnet, use .testnet()."
            ),
        )
    })?;

    let api_url = base_url_override.unwrap_or_else(|| cfg.api_url.to_string());
    let router_addr = router_address.unwrap_or_default();
    let address = signer.address().to_string();
    let transport = Arc::new(HttpTransport::new(
        api_url,
        cfg.chain_id,
        router_addr,
        signer,
    ));

    Ok(Wallet {
        transport,
        address,
        chain_id: ChainId(cfg.chain_id),
        chain: chain.to_string(),
        contracts_cache: Mutex::new(None),
    })
}

// ─── Input validation ─────────────────────────────────────────────────────────

/// Validate an Ethereum address. Returns a descriptive error if invalid.
pub(crate) fn validate_address(addr: &str) -> Result<(), RemitError> {
    let addr = addr.trim();
    let hex_part = addr
        .strip_prefix("0x")
        .or_else(|| addr.strip_prefix("0X"))
        .unwrap_or(addr);

    if hex_part.len() != 40 || !hex_part.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(remit_err_ctx(
            codes::INVALID_ADDRESS,
            format!(
                "invalid address {addr:?}: expected 0x-prefixed 40-character hex string (Ethereum address). See remit.md/docs/errors#INVALID_ADDRESS"
            ),
            "address",
            addr,
        ));
    }
    Ok(())
}

/// Validate a USDC amount. Returns descriptive errors for out-of-range values.
pub(crate) fn validate_amount(amount: Decimal) -> Result<(), RemitError> {
    let min = Decimal::from_str("0.000001").unwrap();
    let max = Decimal::from_str("1000000").unwrap();

    if amount < min {
        return Err(remit_err_ctx(
            codes::INVALID_AMOUNT,
            format!("amount {amount} is below minimum 0.000001 USDC (1 base unit). See remit.md/docs/errors#INVALID_AMOUNT"),
            "minimum",
            "0.000001",
        ));
    }
    if amount > max {
        return Err(remit_err_ctx(
            codes::INVALID_AMOUNT,
            format!("amount {amount} exceeds per-transaction maximum of 1,000,000 USDC. See remit.md/docs/errors#INVALID_AMOUNT"),
            "maximum",
            "1000000",
        ));
    }
    Ok(())
}
