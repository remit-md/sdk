use rust_decimal::Decimal;
use serde_json::{json, Value};
use std::env;
use std::str::FromStr;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;

use crate::cli_signer::{cli_install_hint, CliSigner};
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
///     println!("paid: {:?} in tx {}", tx.amount, tx.tx_hash);
///     Ok(())
/// }
/// ```
///
/// # Testing
///
/// Use `MockRemit` for unit tests - zero network, deterministic:
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
    /// Retained signer reference for permit signing.
    pub(crate) signer: Arc<dyn Signer>,
}

impl Wallet {
    /// Create a wallet from a hex-encoded private key.
    ///
    /// # Arguments
    /// - `private_key` - 32-byte private key as hex (with or without `0x` prefix)
    ///
    /// # Options
    /// - `.testnet()` - use testnet
    /// - `.base_url("http://localhost:3000")` - override API URL
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

    /// Create a wallet from environment variables.
    ///
    /// Signer detection (first match wins):
    /// 1. CLI signer — `remit` on PATH + keystore exists + `REMIT_SIGNER_KEY` set
    /// 2. `REMITMD_KEY` — hex-encoded private key
    ///
    /// Common options:
    /// - `REMITMD_CHAIN` - chain name (default: `"base"`)
    /// - `REMITMD_TESTNET` - `"1"`, `"true"`, or `"yes"` for testnet
    /// - `REMITMD_ROUTER_ADDRESS` - EIP-712 verifying contract address
    pub fn from_env() -> Result<Self, RemitError> {
        let chain = env::var("REMITMD_CHAIN").unwrap_or_else(|_| "base".to_string());
        let testnet = matches!(
            env::var("REMITMD_TESTNET").as_deref(),
            Ok("1") | Ok("true") | Ok("yes")
        );
        let router_address = env::var("REMITMD_ROUTER_ADDRESS").unwrap_or_default();

        // 1. CLI signer (encrypted keystore — most secure)
        if CliSigner::is_available() {
            let signer = CliSigner::new()?;
            let mut builder = Self::with_signer(signer).chain(&chain);
            if testnet {
                builder = builder.testnet();
            }
            if !router_address.is_empty() {
                builder = builder.router_address(&router_address);
            }
            return builder.build();
        }

        // 2. Private key (REMITMD_KEY)
        if let Ok(key) = env::var("REMITMD_KEY") {
            let mut builder = Self::new(&key).chain(&chain);
            if testnet {
                builder = builder.testnet();
            }
            if !router_address.is_empty() {
                builder = builder.router_address(&router_address);
            }
            return builder.build();
        }

        Err(remit_err_ctx(
            codes::UNAUTHORIZED,
            format!(
                "No signing credentials found. Install the Remit CLI and set REMIT_SIGNER_KEY, or set REMITMD_KEY.\nInstall CLI: {}",
                cli_install_hint()
            ),
            "hint",
            "export REMITMD_KEY=0x... or install remit CLI",
        ))
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

// ─── EIP-2612 Permit (via /permits/prepare) ─────────────────────────────────

/// Contract name to flow name for /permits/prepare.
const CONTRACT_TO_FLOW: &[(&str, &str)] = &[
    ("router", "direct"),
    ("escrow", "escrow"),
    ("tab", "tab"),
    ("stream", "stream"),
    ("bounty", "bounty"),
    ("deposit", "deposit"),
    ("relayer", "direct"),
];

impl Wallet {
    /// Sign a USDC permit via the server's `/permits/prepare` endpoint.
    ///
    /// The server computes the EIP-712 hash, manages nonces, and resolves
    /// contract addresses. The SDK only signs the hash.
    ///
    /// # Arguments
    /// - `flow` - payment flow (`"direct"`, `"escrow"`, `"tab"`, `"stream"`, `"bounty"`, `"deposit"`)
    /// - `amount` - USDC amount (e.g. 5.0 for $5.00)
    pub async fn sign_permit(
        &self,
        flow: &str,
        amount: f64,
    ) -> Result<PermitSignature, RemitError> {
        let data: Value = self
            .transport
            .post(
                "/api/v1/permits/prepare",
                Some(json!({
                    "flow": flow,
                    "amount": amount.to_string(),
                    "owner": self.address,
                })),
            )
            .await?;

        let hash_hex = data["hash"]
            .as_str()
            .ok_or_else(|| remit_err(codes::SERVER_ERROR, "permits/prepare: missing hash"))?;
        let hash_str = hash_hex.strip_prefix("0x").unwrap_or(hash_hex);
        let hash_bytes_vec = hex::decode(hash_str).map_err(|e| {
            remit_err(
                codes::SERVER_ERROR,
                format!("permits/prepare: invalid hash hex: {e}"),
            )
        })?;
        if hash_bytes_vec.len() != 32 {
            return Err(remit_err(
                codes::SERVER_ERROR,
                format!(
                    "permits/prepare: expected 32-byte hash, got {}",
                    hash_bytes_vec.len()
                ),
            ));
        }
        let mut hash: [u8; 32] = [0u8; 32];
        hash.copy_from_slice(&hash_bytes_vec);

        let sig_hex = self.signer.sign_hash(&hash)?;
        let sig_raw = sig_hex.strip_prefix("0x").unwrap_or(&sig_hex);
        if sig_raw.len() != 130 {
            return Err(remit_err(
                codes::INVALID_SIGNATURE,
                format!(
                    "expected 65-byte signature (130 hex chars), got {}",
                    sig_raw.len()
                ),
            ));
        }
        let r = format!("0x{}", &sig_raw[..64]);
        let s = format!("0x{}", &sig_raw[64..128]);
        let v = u8::from_str_radix(&sig_raw[128..130], 16).unwrap_or(0);

        let value = data["value"]
            .as_str()
            .or_else(|| data["value"].as_u64().map(|_| ""))
            .and_then(|s| {
                if s.is_empty() {
                    data["value"].as_u64()
                } else {
                    s.parse::<u64>().ok()
                }
            })
            .unwrap_or(0);
        let deadline = data["deadline"]
            .as_str()
            .or_else(|| data["deadline"].as_u64().map(|_| ""))
            .and_then(|s| {
                if s.is_empty() {
                    data["deadline"].as_u64()
                } else {
                    s.parse::<u64>().ok()
                }
            })
            .unwrap_or(0);

        Ok(PermitSignature {
            value,
            deadline,
            v,
            r,
            s,
        })
    }

    /// Internal: auto-sign a permit via `/permits/prepare`.
    ///
    /// Maps the contract name to a flow and calls `sign_permit()`.
    /// Returns `None` on failure so callers degrade gracefully.
    async fn try_auto_permit(&self, contract: &str, amount: Decimal) -> Option<PermitSignature> {
        let flow = CONTRACT_TO_FLOW
            .iter()
            .find(|(k, _)| *k == contract)
            .map(|(_, v)| *v);
        let flow = match flow {
            Some(f) => f,
            None => {
                eprintln!("[remitmd] unknown contract for permit: {contract}");
                return None;
            }
        };
        let amount_f64 = match decimal_to_f64(amount) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("[remitmd] auto_permit skipped: amount conversion failed: {e}");
                return None;
            }
        };
        match self.sign_permit(flow, amount_f64).await {
            Ok(permit) => Some(permit),
            Err(e) => {
                eprintln!(
                    "[remitmd] auto_permit for {contract} failed (falling back to server-side approval): {e}"
                );
                None
            }
        }
    }
}

// ─── Payment methods ─────────────────────────────────────────────────────────

impl Wallet {
    /// Return the full wallet status including balance, volume, fee tier, and active counts.
    pub async fn status(&self) -> Result<WalletStatus, RemitError> {
        self.get(&format!("/api/v1/status/{}", self.address)).await
    }

    /// Return the current USDC balance of this wallet.
    ///
    /// Calls the `/api/v1/status/{address}` endpoint and parses the balance.
    pub async fn balance(&self) -> Result<Balance, RemitError> {
        let ws: WalletStatus = self.status().await?;
        let usdc = Decimal::from_str(&ws.balance).unwrap_or_default();
        Ok(Balance {
            usdc,
            address: ws.wallet,
            chain_id: self.chain_id,
            updated_at: chrono::Utc::now(),
        })
    }

    /// Send a direct USDC payment.
    ///
    /// Direct payments are one-way transfers with no escrow or refund mechanism.
    /// For reversible payments, use `create_escrow`.
    ///
    /// # Arguments
    /// - `to` - recipient Ethereum address
    /// - `amount` - USDC amount (minimum: 0.000001, maximum: 1,000,000)
    ///
    /// # Example
    /// ```rust,ignore
    /// use rust_decimal_macros::dec;
    /// let tx = wallet.pay("0xAgent...", dec!(0.003)).await?;
    /// ```
    pub async fn pay(&self, to: &str, amount: Decimal) -> Result<Transaction, RemitError> {
        let permit = self.try_auto_permit("router", amount).await;
        self.pay_full(to, amount, "", permit).await
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
        let permit = self.try_auto_permit("router", amount).await;
        self.pay_full(to, amount, memo, permit).await
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
        self.post("/api/v1/payments/direct", body).await
    }

    /// Return paginated transaction history.
    ///
    /// # Arguments
    /// - `page` - 1-indexed page number (default: 1)
    /// - `per_page` - results per page (default: 20, max: 100)
    pub async fn history(&self, page: u32, per_page: u32) -> Result<TransactionList, RemitError> {
        let per_page = per_page.clamp(1, 100);
        let path = format!("/api/v1/wallet/history?page={page}&per_page={per_page}");
        self.get(&path).await
    }

    /// Return the on-chain reputation for any Ethereum address.
    pub async fn reputation(&self, address: &str) -> Result<Reputation, RemitError> {
        validate_address(address)?;
        self.get(&format!("/api/v1/reputation/{address}")).await
    }

    /// Return spending analytics for this wallet.
    ///
    /// # Arguments
    /// - `period` - `"day"`, `"week"`, `"month"`, or `"all"`
    pub async fn spending_summary(&self, period: &str) -> Result<SpendingSummary, RemitError> {
        self.get(&format!("/api/v1/wallet/spending?period={period}"))
            .await
    }

    /// Return the remaining spending budget under operator-set limits.
    pub async fn remaining_budget(&self) -> Result<Budget, RemitError> {
        self.get("/api/v1/wallet/budget").await
    }

    // ─── Escrow ──────────────────────────────────────────────────────────────

    /// Create and fund an escrow for work to be done.
    ///
    /// Funds are locked until the payer calls `release_escrow` or the escrow
    /// expires. Use for high-value tasks where delivery must be verified before
    /// payment.
    ///
    /// # Arguments
    /// - `payee` - the agent that will receive funds on release
    /// - `amount` - total USDC to lock
    pub async fn create_escrow(&self, payee: &str, amount: Decimal) -> Result<Escrow, RemitError> {
        let permit = self.try_auto_permit("escrow", amount).await;
        self.create_escrow_full(payee, amount, "", &[], &[], None, permit)
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
            "amount": decimal_to_f64(amount)?,
            "type": "escrow",
            "task": memo,
            "nonce": hex::encode(nb),
            "signature": "0x",
        });
        if let Some(secs) = expires_in_secs {
            inv_body["escrow_timeout"] = json!(secs);
        }
        // Discard response (server returns 201 with invoice data).
        let _: serde_json::Value = self.post("/api/v1/invoices", inv_body).await?;

        // Step 2: fund the escrow.
        let mut escrow_body = json!({ "invoice_id": invoice_id });
        if let Some(p) = permit {
            escrow_body["permit"] = serde_json::to_value(p).unwrap();
        }
        self.post("/api/v1/escrows", escrow_body).await
    }

    /// Signal that the payee has started work on an escrow.
    ///
    /// Must be called by the payee before the payer can release funds.
    pub async fn claim_start(&self, escrow_id: &str) -> Result<Escrow, RemitError> {
        self.post(
            &format!("/api/v1/escrows/{escrow_id}/claim-start"),
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
        self.post(&format!("/api/v1/escrows/{escrow_id}/release"), body)
            .await
    }

    /// Cancel the escrow and return funds to the payer.
    pub async fn cancel_escrow(&self, escrow_id: &str) -> Result<Escrow, RemitError> {
        self.post(&format!("/api/v1/escrows/{escrow_id}/cancel"), json!({}))
            .await
    }

    /// Fetch the current state of an escrow.
    pub async fn get_escrow(&self, escrow_id: &str) -> Result<Escrow, RemitError> {
        self.get(&format!("/api/v1/escrows/{escrow_id}")).await
    }

    /// Submit evidence for an escrow milestone.
    ///
    /// # Arguments
    /// - `invoice_id` - the escrow invoice ID
    /// - `evidence_uri` - URI pointing to the evidence (e.g. IPFS hash)
    /// - `milestone_index` - optional milestone index (0-based)
    pub async fn submit_evidence(
        &self,
        invoice_id: &str,
        evidence_uri: &str,
        milestone_index: Option<u32>,
    ) -> Result<Value, RemitError> {
        let mut body = json!({ "evidence_uri": evidence_uri });
        if let Some(idx) = milestone_index {
            body["milestone_index"] = json!(idx);
        }
        self.post(&format!("/api/v1/escrows/{invoice_id}/evidence"), body)
            .await
    }

    /// Release a specific milestone within an escrow.
    ///
    /// # Arguments
    /// - `invoice_id` - the escrow invoice ID
    /// - `milestone_index` - the milestone index to release (0-based)
    pub async fn release_milestone(
        &self,
        invoice_id: &str,
        milestone_index: u32,
    ) -> Result<Escrow, RemitError> {
        self.post(
            &format!("/api/v1/escrows/{invoice_id}/release"),
            json!({ "milestone_index": milestone_index }),
        )
        .await
    }

    // ─── Tab ─────────────────────────────────────────────────────────────────

    /// Open a payment channel for batched micro-payments.
    ///
    /// Tabs are ideal for high-frequency low-value payments (e.g., per-token LLM
    /// billing, per-query data APIs). Charges are provider-signed; settlement is on-chain.
    ///
    /// # Arguments
    /// - `provider` - the agent receiving payments
    /// - `limit_amount` - maximum USDC pre-deposited into the channel
    /// - `per_unit` - USDC per unit/call
    pub async fn create_tab(
        &self,
        provider: &str,
        limit_amount: Decimal,
        per_unit: Decimal,
    ) -> Result<Tab, RemitError> {
        let permit = self.try_auto_permit("tab", limit_amount).await;
        self.create_tab_full(provider, limit_amount, per_unit, None, permit)
            .await
    }

    /// Open a tab with a permit for gasless approval.
    pub async fn create_tab_with_permit(
        &self,
        provider: &str,
        limit_amount: Decimal,
        per_unit: Decimal,
        permit: PermitSignature,
    ) -> Result<Tab, RemitError> {
        self.create_tab_full(provider, limit_amount, per_unit, None, Some(permit))
            .await
    }

    /// Open a tab with a custom expiry.
    pub async fn create_tab_with_expiry(
        &self,
        provider: &str,
        limit_amount: Decimal,
        per_unit: Decimal,
        expiry: u64,
    ) -> Result<Tab, RemitError> {
        let permit = self.try_auto_permit("tab", limit_amount).await;
        self.create_tab_full(provider, limit_amount, per_unit, Some(expiry), permit)
            .await
    }

    /// Open a tab with optional expiry and permit.
    pub async fn create_tab_full(
        &self,
        provider: &str,
        limit_amount: Decimal,
        per_unit: Decimal,
        expiry: Option<u64>,
        permit: Option<PermitSignature>,
    ) -> Result<Tab, RemitError> {
        validate_address(provider)?;
        let exp = expiry.unwrap_or_else(|| {
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs()
                + 86400
        });
        let mut body = json!({
            "chain": &self.chain,
            "provider": provider,
            "limit_amount": decimal_to_f64(limit_amount)?,
            "per_unit": decimal_to_f64(per_unit)?,
            "expiry": exp,
        });
        if let Some(p) = permit {
            body["permit"] = serde_json::to_value(p).unwrap();
        }
        self.post("/api/v1/tabs", body).await
    }

    /// Charge a tab (called by the provider with an EIP-712 signature).
    ///
    /// # Arguments
    /// - `tab_id` - the tab to charge
    /// - `amount` - this individual charge amount in USDC
    /// - `cumulative` - total cumulative amount charged so far (including this charge)
    /// - `call_count` - total number of charges so far (including this one)
    /// - `provider_sig` - EIP-712 TabCharge signature from the provider
    pub async fn charge_tab(
        &self,
        tab_id: &str,
        amount: f64,
        cumulative: f64,
        call_count: u32,
        provider_sig: &str,
    ) -> Result<TabCharge, RemitError> {
        self.post(
            &format!("/api/v1/tabs/{tab_id}/charge"),
            json!({
                "amount": amount,
                "cumulative": cumulative,
                "call_count": call_count,
                "provider_sig": provider_sig,
            }),
        )
        .await
    }

    /// Close the tab with a final settlement amount and provider signature.
    ///
    /// # Arguments
    /// - `tab_id` - the tab to close
    /// - `final_amount` - final settled USDC amount
    /// - `provider_sig` - EIP-712 TabCharge signature from the provider
    pub async fn close_tab(
        &self,
        tab_id: &str,
        final_amount: f64,
        provider_sig: &str,
    ) -> Result<Tab, RemitError> {
        self.post(
            &format!("/api/v1/tabs/{tab_id}/close"),
            json!({
                "final_amount": final_amount,
                "provider_sig": provider_sig,
            }),
        )
        .await
    }

    /// Close the tab and settle all charges on-chain (compat alias for `close_tab`).
    #[deprecated(note = "use close_tab() instead")]
    pub async fn settle_tab(
        &self,
        tab_id: &str,
        final_amount: f64,
        provider_sig: &str,
    ) -> Result<Tab, RemitError> {
        self.close_tab(tab_id, final_amount, provider_sig).await
    }

    /// Debit a charge from an open tab (off-chain, signed). Legacy method.
    #[deprecated(note = "use charge_tab() instead")]
    pub async fn debit_tab(
        &self,
        tab_id: &str,
        amount: Decimal,
        memo: &str,
    ) -> Result<TabDebit, RemitError> {
        validate_amount(amount)?;
        self.post(
            &format!("/api/v1/tabs/{tab_id}/debit"),
            json!({
                "tab_id": tab_id,
                "amount": amount.to_string(),
                "memo": memo,
            }),
        )
        .await
    }

    // ─── Stream ──────────────────────────────────────────────────────────────

    /// Start a per-second USDC payment stream.
    ///
    /// Streams are ideal for subscription-style payments where the recipient
    /// provides ongoing value (compute time, uptime guarantees, etc.).
    ///
    /// # Arguments
    /// - `payee` - the agent receiving the stream
    /// - `rate_per_second` - USDC per second
    /// - `max_total` - total USDC pre-deposited (determines stream duration)
    pub async fn create_stream(
        &self,
        payee: &str,
        rate_per_second: Decimal,
        max_total: Decimal,
    ) -> Result<Stream, RemitError> {
        let permit = self.try_auto_permit("stream", max_total).await;
        self.create_stream_with_permit(payee, rate_per_second, max_total, permit)
            .await
    }

    /// Start a per-second USDC payment stream with an optional permit.
    pub async fn create_stream_with_permit(
        &self,
        payee: &str,
        rate_per_second: Decimal,
        max_total: Decimal,
        permit: Option<PermitSignature>,
    ) -> Result<Stream, RemitError> {
        validate_address(payee)?;
        validate_amount(max_total)?;
        let mut body = json!({
            "chain": &self.chain,
            "payee": payee,
            "rate_per_second": decimal_to_f64(rate_per_second)?,
            "max_total": decimal_to_f64(max_total)?,
        });
        if let Some(p) = permit {
            body["permit"] = serde_json::to_value(p).unwrap();
        }
        self.post("/api/v1/streams", body).await
    }

    /// Close an active stream (called by the payer).
    pub async fn close_stream(&self, stream_id: &str) -> Result<Stream, RemitError> {
        self.post(&format!("/api/v1/streams/{stream_id}/close"), json!({}))
            .await
    }

    /// Withdraw all vested stream payments (called by the recipient).
    pub async fn withdraw_stream(&self, stream_id: &str) -> Result<Transaction, RemitError> {
        self.post(&format!("/api/v1/streams/{stream_id}/withdraw"), json!({}))
            .await
    }

    // ─── Bounty ──────────────────────────────────────────────────────────────

    /// Post a USDC bounty for task completion.
    ///
    /// Any agent can submit work; the poster awards the bounty to the winner.
    ///
    /// # Arguments
    /// - `amount` - USDC prize for the winner
    /// - `task_description` - task description (agent-readable)
    /// - `deadline` - unix timestamp when the bounty expires
    pub async fn create_bounty(
        &self,
        amount: Decimal,
        task_description: &str,
        deadline: u64,
    ) -> Result<Bounty, RemitError> {
        let permit = self.try_auto_permit("bounty", amount).await;
        self.create_bounty_full(amount, task_description, deadline, None, permit)
            .await
    }

    /// Create a bounty with a permit for gasless approval.
    pub async fn create_bounty_with_permit(
        &self,
        amount: Decimal,
        task_description: &str,
        deadline: u64,
        permit: PermitSignature,
    ) -> Result<Bounty, RemitError> {
        self.create_bounty_full(amount, task_description, deadline, None, Some(permit))
            .await
    }

    /// Create a bounty with all options.
    pub async fn create_bounty_full(
        &self,
        amount: Decimal,
        task_description: &str,
        deadline: u64,
        max_attempts: Option<u32>,
        permit: Option<PermitSignature>,
    ) -> Result<Bounty, RemitError> {
        validate_amount(amount)?;
        let ma = max_attempts.unwrap_or(10);
        let mut body = json!({
            "chain": &self.chain,
            "amount": decimal_to_f64(amount)?,
            "task_description": task_description,
            "deadline": deadline,
            "max_attempts": ma,
        });
        if let Some(p) = permit {
            body["permit"] = serde_json::to_value(p).unwrap();
        }
        self.post("/api/v1/bounties", body).await
    }

    /// Submit evidence for a bounty.
    ///
    /// Returns a JSON value containing the submission (with `id` field for the submission ID).
    pub async fn submit_bounty(
        &self,
        bounty_id: &str,
        evidence_hash: &str,
    ) -> Result<BountySubmission, RemitError> {
        self.post(
            &format!("/api/v1/bounties/{bounty_id}/submit"),
            json!({ "evidence_hash": evidence_hash }),
        )
        .await
    }

    /// Award a bounty to a submission.
    pub async fn award_bounty(
        &self,
        bounty_id: &str,
        submission_id: i64,
    ) -> Result<Bounty, RemitError> {
        self.post(
            &format!("/api/v1/bounties/{bounty_id}/award"),
            json!({ "submission_id": submission_id }),
        )
        .await
    }

    /// List bounties with optional filters.
    ///
    /// # Arguments
    /// - `status` - filter by status (open, claimed, awarded, expired)
    /// - `poster` - filter by poster wallet address
    /// - `submitter` - filter by submitter wallet address
    /// - `limit` - max results (default 20, max 100)
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
        let resp: Resp = self.get(&format!("/api/v1/bounties{qs}")).await?;
        Ok(resp.data)
    }

    // ─── Deposit ─────────────────────────────────────────────────────────────

    /// Lock a security deposit with a provider.
    ///
    /// The depositor's funds are locked until the provider returns them,
    /// the depositor requests return (after the lock period), or the deposit expires.
    ///
    /// # Arguments
    /// - `provider` - address that can forfeit the deposit
    /// - `amount` - USDC to lock
    /// - `expiry` - unix timestamp when the deposit expires
    pub async fn lock_deposit(
        &self,
        provider: &str,
        amount: Decimal,
        expiry: u64,
    ) -> Result<Deposit, RemitError> {
        let permit = self.try_auto_permit("deposit", amount).await;
        self.lock_deposit_full(provider, amount, expiry, permit)
            .await
    }

    /// Lock a security deposit with a permit for gasless approval.
    pub async fn lock_deposit_with_permit(
        &self,
        provider: &str,
        amount: Decimal,
        expiry: u64,
        permit: PermitSignature,
    ) -> Result<Deposit, RemitError> {
        self.lock_deposit_full(provider, amount, expiry, Some(permit))
            .await
    }

    /// Lock a security deposit with optional permit.
    pub async fn lock_deposit_full(
        &self,
        provider: &str,
        amount: Decimal,
        expiry: u64,
        permit: Option<PermitSignature>,
    ) -> Result<Deposit, RemitError> {
        validate_address(provider)?;
        validate_amount(amount)?;
        let mut body = json!({
            "chain": &self.chain,
            "provider": provider,
            "amount": decimal_to_f64(amount)?,
            "expiry": expiry,
        });
        if let Some(p) = permit {
            body["permit"] = serde_json::to_value(p).unwrap();
        }
        self.post("/api/v1/deposits", body).await
    }

    /// Return a security deposit to the depositor.
    pub async fn return_deposit(&self, deposit_id: &str) -> Result<Value, RemitError> {
        self.post(&format!("/api/v1/deposits/{deposit_id}/return"), json!({}))
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
            "/api/v1/intents",
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
    /// - `url` - the HTTPS endpoint that will receive POST notifications
    /// - `events` - event types to subscribe to (e.g. `["payment.sent", "escrow.funded"]`)
    /// - `chains` - optional list of chain names to filter by (e.g. `["base"]`)
    pub async fn register_webhook(
        &self,
        url: &str,
        events: &[&str],
        chains: Option<&[&str]>,
    ) -> Result<Webhook, RemitError> {
        let chain_list: Vec<&str> = match chains {
            Some(c) => c.to_vec(),
            None => vec![&self.chain],
        };
        let body = json!({
            "url": url,
            "events": events,
            "chains": chain_list,
        });
        self.post("/api/v1/webhooks", body).await
    }

    /// List all registered webhooks for this wallet.
    pub async fn list_webhooks(&self) -> Result<Vec<Webhook>, RemitError> {
        let val = self.transport.get("/api/v1/webhooks").await?;
        serde_json::from_value(val).map_err(|e| RemitError::new("PARSE_ERROR", e.to_string()))
    }

    /// Delete a webhook by ID.
    pub async fn delete_webhook(&self, webhook_id: &str) -> Result<(), RemitError> {
        self.transport
            .delete(&format!("/api/v1/webhooks/{}", webhook_id))
            .await?;
        Ok(())
    }

    // ─── Aliases (canonical names) ───────────────────────────────────────────

    /// Canonical name for `create_tab`.
    pub async fn open_tab(
        &self,
        provider: &str,
        limit: Decimal,
        per_unit: Decimal,
    ) -> Result<Tab, RemitError> {
        self.create_tab(provider, limit, per_unit).await
    }

    /// Canonical name for `create_stream`.
    pub async fn open_stream(
        &self,
        payee: &str,
        rate_per_second: Decimal,
        max_total: Decimal,
    ) -> Result<Stream, RemitError> {
        self.create_stream(payee, rate_per_second, max_total).await
    }

    /// Canonical name for `create_bounty`.
    pub async fn post_bounty(
        &self,
        amount: Decimal,
        task: &str,
        deadline: u64,
    ) -> Result<Bounty, RemitError> {
        self.create_bounty(amount, task, deadline).await
    }

    /// Canonical name for `lock_deposit`.
    pub async fn place_deposit(
        &self,
        provider: &str,
        amount: Decimal,
        expires_in_secs: u64,
    ) -> Result<Deposit, RemitError> {
        self.lock_deposit(provider, amount, expires_in_secs).await
    }

    /// Alias for propose_intent.
    pub async fn express_intent(
        &self,
        to: &str,
        amount: Decimal,
        payment_type: &str,
    ) -> Result<Intent, RemitError> {
        self.propose_intent(to, amount, payment_type).await
    }

    /// Generate a one-time URL for the operator to fund this wallet.
    pub async fn create_fund_link(&self) -> Result<LinkResponse, RemitError> {
        self.create_fund_link_with_options(None, None).await
    }

    /// Generate a one-time URL for the operator to fund this wallet,
    /// with optional chat-style messages and agent name displayed on the funding page.
    ///
    /// Automatically signs a permit for the relayer so the fund operation can proceed
    /// without a separate on-chain approval. If permit signing fails (e.g., RPC
    /// unreachable), the link is still created without a permit.
    pub async fn create_fund_link_with_options(
        &self,
        messages: Option<&[LinkMessage]>,
        agent_name: Option<&str>,
    ) -> Result<LinkResponse, RemitError> {
        let mut body = json!({});
        if let Some(msgs) = messages {
            body["messages"] = serde_json::to_value(msgs).unwrap();
        }
        if let Some(name) = agent_name {
            body["agent_name"] = json!(name);
        }
        // Auto-sign a permit for the relayer (best-effort)
        match self.sign_permit("direct", 999_999_999.0).await {
            Ok(permit) => {
                body["permit"] = serde_json::to_value(&permit).unwrap();
            }
            Err(e) => {
                eprintln!("[remitmd] fund link: sign_permit for relayer failed (link created without permit): {e}");
            }
        }
        self.post("/api/v1/links/fund", body).await
    }

    /// Generate a one-time URL for the operator to withdraw funds.
    pub async fn create_withdraw_link(&self) -> Result<LinkResponse, RemitError> {
        self.create_withdraw_link_with_options(None, None).await
    }

    /// Generate a one-time URL for the operator to withdraw funds,
    /// with optional chat-style messages and agent name displayed on the withdraw page.
    ///
    /// Automatically signs a permit for the relayer so the withdraw can proceed
    /// without a separate on-chain approval. If permit signing fails (e.g., RPC
    /// unreachable), the link is still created without a permit.
    pub async fn create_withdraw_link_with_options(
        &self,
        messages: Option<&[LinkMessage]>,
        agent_name: Option<&str>,
    ) -> Result<LinkResponse, RemitError> {
        let mut body = json!({});
        if let Some(msgs) = messages {
            body["messages"] = serde_json::to_value(msgs).unwrap();
        }
        if let Some(name) = agent_name {
            body["agent_name"] = json!(name);
        }
        // Auto-sign a permit for the relayer (best-effort)
        match self.sign_permit("direct", 999_999_999.0).await {
            Ok(permit) => {
                body["permit"] = serde_json::to_value(&permit).unwrap();
            }
            Err(e) => {
                eprintln!("[remitmd] withdraw link: sign_permit for relayer failed (link created without permit): {e}");
            }
        }
        self.post("/api/v1/links/withdraw", body).await
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
        let contracts: ContractAddresses = self.get("/api/v1/contracts").await?;
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
    /// - `amount` - USDC amount to mint
    pub async fn mint(&self, amount: f64) -> Result<MintResponse, RemitError> {
        self.post(
            "/api/v1/mint",
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

    let api_url = base_url_override
        .or_else(|| env::var("REMITMD_API_URL").ok())
        .unwrap_or_else(|| cfg.api_url.to_string());
    let router_addr = router_address.unwrap_or_default();
    let address = signer.address().to_string();

    let transport = Arc::new(HttpTransport::new(
        api_url,
        cfg.chain_id,
        router_addr,
        signer.clone(),
    ));

    Ok(Wallet {
        transport,
        address,
        chain_id: ChainId(cfg.chain_id),
        chain: chain.to_string(),
        contracts_cache: Mutex::new(None),
        signer,
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

/// Convert a `Decimal` USDC amount to `f64` for permit signing and API serialization.
///
/// Returns an error instead of silently defaulting to zero - financial amounts
/// must never be quietly zeroed out.
fn decimal_to_f64(d: Decimal) -> Result<f64, RemitError> {
    d.to_string().parse::<f64>().map_err(|e| {
        remit_err(
            codes::INVALID_AMOUNT,
            format!("failed to convert amount {d} to f64: {e}"),
        )
    })
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
