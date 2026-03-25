//! x402 client and paywall for HTTP 402 Payment Required flows.
//!
//! x402 is an open payment standard where resource servers return HTTP 402 with
//! a `PAYMENT-REQUIRED` header describing the cost. This module provides:
//!
//! - [`X402Client`] — a `fetch` wrapper that auto-pays 402 responses
//! - [`X402Paywall`] — server-side middleware for gating endpoints behind payments
//!
//! # Client usage
//!
//! ```rust,ignore
//! use remitmd::x402::X402Client;
//! use remitmd::Wallet;
//!
//! let wallet = Wallet::from_env()?;
//! let client = X402Client::new(wallet, 0.10);
//! let response = client.fetch("https://api.provider.com/v1/data").await?;
//! ```

use serde::{Deserialize, Serialize};
use std::fmt;

use crate::error::{codes, RemitError};

/// Raised when an x402 payment amount exceeds the configured auto-pay limit.
#[derive(Debug, Clone)]
pub struct AllowanceExceededError {
    pub amount_usdc: f64,
    pub limit_usdc: f64,
}

impl fmt::Display for AllowanceExceededError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "x402 payment {:.6} USDC exceeds auto-pay limit {:.6} USDC",
            self.amount_usdc, self.limit_usdc
        )
    }
}

impl std::error::Error for AllowanceExceededError {}

/// Shape of the base64-decoded PAYMENT-REQUIRED header (V2).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PaymentRequired {
    pub scheme: String,
    pub network: String,
    pub amount: String,
    pub asset: String,
    pub pay_to: String,
    #[serde(default)]
    pub max_timeout_seconds: Option<u64>,
    /// V2 — URL or path of the resource being protected.
    #[serde(default)]
    pub resource: Option<String>,
    /// V2 — Human-readable description of what the payment is for.
    #[serde(default)]
    pub description: Option<String>,
    /// V2 — MIME type of the resource.
    #[serde(default)]
    pub mime_type: Option<String>,
}

/// Response from an x402 fetch operation.
#[derive(Debug)]
pub struct X402Response {
    pub status: u16,
    pub body: String,
    pub headers: Vec<(String, String)>,
}

/// `fetch` wrapper that auto-handles HTTP 402 Payment Required responses.
///
/// On receiving a 402, the client:
/// 1. Decodes the `PAYMENT-REQUIRED` header (base64 JSON)
/// 2. Checks the amount is within `max_auto_pay_usdc`
/// 3. Builds and signs an EIP-3009 `transferWithAuthorization`
/// 4. Base64-encodes the `PAYMENT-SIGNATURE` header
/// 5. Retries the original request with payment attached
pub struct X402Client {
    wallet: crate::Wallet,
    max_auto_pay_usdc: f64,
    /// The last PAYMENT-REQUIRED decoded before payment. Useful for logging.
    pub last_payment: Option<PaymentRequired>,
}

impl X402Client {
    /// Create a new X402 client.
    ///
    /// # Arguments
    /// - `wallet` — the wallet used for signing payment authorizations
    /// - `max_auto_pay_usdc` — maximum USDC per request to auto-pay (default: 0.10)
    pub fn new(wallet: crate::Wallet, max_auto_pay_usdc: f64) -> Self {
        Self {
            wallet,
            max_auto_pay_usdc,
            last_payment: None,
        }
    }

    /// Make an HTTP GET request, auto-paying any 402 responses within the configured limit.
    pub async fn fetch(&mut self, url: &str) -> Result<X402Response, RemitError> {
        let client = reqwest::Client::new();
        let resp = client.get(url).send().await.map_err(|e| {
            RemitError::new(codes::NETWORK_ERROR, format!("x402 fetch failed: {e}"))
        })?;

        if resp.status().as_u16() == 402 {
            return self.handle_402(url, &resp).await;
        }

        let status = resp.status().as_u16();
        let headers: Vec<(String, String)> = resp
            .headers()
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_str().unwrap_or("").to_string()))
            .collect();
        let body = resp.text().await.unwrap_or_default();
        Ok(X402Response {
            status,
            body,
            headers,
        })
    }

    async fn handle_402(
        &mut self,
        url: &str,
        resp: &reqwest::Response,
    ) -> Result<X402Response, RemitError> {
        // 1. Decode PAYMENT-REQUIRED header.
        let raw = resp
            .headers()
            .get("payment-required")
            .ok_or_else(|| {
                RemitError::new(
                    codes::SERVER_ERROR,
                    "402 response missing PAYMENT-REQUIRED header",
                )
            })?
            .to_str()
            .map_err(|_| {
                RemitError::new(codes::SERVER_ERROR, "invalid PAYMENT-REQUIRED header encoding")
            })?;

        use base64::Engine;
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(raw)
            .map_err(|_| {
                RemitError::new(codes::SERVER_ERROR, "PAYMENT-REQUIRED header is not valid base64")
            })?;

        let required: PaymentRequired = serde_json::from_slice(&decoded).map_err(|e| {
            RemitError::new(
                codes::SERVER_ERROR,
                format!("failed to parse PAYMENT-REQUIRED: {e}"),
            )
        })?;

        // 2. Only the "exact" scheme is supported.
        if required.scheme != "exact" {
            return Err(RemitError::new(
                codes::SERVER_ERROR,
                format!("unsupported x402 scheme: {}", required.scheme),
            ));
        }

        // Store for caller inspection.
        self.last_payment = Some(required.clone());

        // 3. Check auto-pay limit.
        let amount_base_units: u64 = required.amount.parse().unwrap_or(0);
        let amount_usdc = amount_base_units as f64 / 1_000_000.0;
        if amount_usdc > self.max_auto_pay_usdc {
            return Err(RemitError::new(
                codes::SERVER_ERROR,
                format!(
                    "x402 payment {:.6} USDC exceeds auto-pay limit {:.6} USDC",
                    amount_usdc, self.max_auto_pay_usdc
                ),
            ));
        }

        // 4. Parse chainId from CAIP-2 network string (e.g. "eip155:84532").
        let chain_id: u64 = required
            .network
            .split(':')
            .nth(1)
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);

        // 5. Build EIP-3009 authorization fields.
        let now_secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let valid_before = now_secs + required.max_timeout_seconds.unwrap_or(60);

        let mut nonce_bytes = [0u8; 32];
        getrandom::getrandom(&mut nonce_bytes)
            .map_err(|_| RemitError::new(codes::SERVER_ERROR, "random generation failed"))?;
        let nonce = format!("0x{}", hex::encode(nonce_bytes));

        // 6. Build EIP-712 typed data hash for TransferWithAuthorization.
        let domain_separator = eip712_domain_separator(
            chain_id,
            &required.asset,
        );
        let struct_hash = eip3009_struct_hash(
            self.wallet.address(),
            &required.pay_to,
            amount_base_units,
            0,
            valid_before,
            &nonce_bytes,
        );
        let digest = eip712_digest(&domain_separator, &struct_hash);

        let sig_bytes = self.wallet.signer.sign(&digest)?;
        let signature = format!("0x{}", hex::encode(&sig_bytes));

        // 7. Build PAYMENT-SIGNATURE JSON payload.
        let payment_payload = serde_json::json!({
            "scheme": required.scheme,
            "network": required.network,
            "x402Version": 1,
            "payload": {
                "signature": signature,
                "authorization": {
                    "from": self.wallet.address(),
                    "to": required.pay_to,
                    "value": required.amount,
                    "validAfter": "0",
                    "validBefore": valid_before.to_string(),
                    "nonce": nonce,
                },
            },
        });
        let payment_header = base64::engine::general_purpose::STANDARD
            .encode(serde_json::to_string(&payment_payload).unwrap());

        // 8. Retry with PAYMENT-SIGNATURE header.
        let client = reqwest::Client::new();
        let retry_resp = client
            .get(url)
            .header("PAYMENT-SIGNATURE", &payment_header)
            .send()
            .await
            .map_err(|e| {
                RemitError::new(
                    codes::NETWORK_ERROR,
                    format!("x402 retry fetch failed: {e}"),
                )
            })?;

        let status = retry_resp.status().as_u16();
        let headers: Vec<(String, String)> = retry_resp
            .headers()
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_str().unwrap_or("").to_string()))
            .collect();
        let body = retry_resp.text().await.unwrap_or_default();
        Ok(X402Response {
            status,
            body,
            headers,
        })
    }
}

// ─── X402Paywall (server-side) ───────────────────────────────────────────────

/// Configuration for [`X402Paywall`].
#[derive(Debug, Clone)]
pub struct PaywallOptions {
    /// Provider's checksummed Ethereum address (the `payTo` field).
    pub wallet_address: String,
    /// Price per request in USDC (e.g. 0.001).
    pub amount_usdc: f64,
    /// CAIP-2 network string (e.g. `"eip155:84532"` for Base Sepolia).
    pub network: String,
    /// USDC contract address on the target network.
    pub asset: String,
    /// Base URL of the remit.md facilitator (default: `"https://remit.md"`).
    pub facilitator_url: Option<String>,
    /// Bearer JWT for authenticating calls to `/api/v1/x402/verify`.
    pub facilitator_token: Option<String>,
    /// How long the payment authorization remains valid (default: 60).
    pub max_timeout_seconds: Option<u64>,
    /// V2 — URL or path of the resource being protected.
    pub resource: Option<String>,
    /// V2 — Human-readable description of what the payment is for.
    pub description: Option<String>,
    /// V2 — MIME type of the resource.
    pub mime_type: Option<String>,
}

/// Result of [`X402Paywall::check`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckResult {
    pub is_valid: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub invalid_reason: Option<String>,
}

/// x402 paywall for service providers — returns 402 when payment is absent/invalid.
pub struct X402Paywall {
    wallet_address: String,
    amount_base_units: String,
    network: String,
    asset: String,
    facilitator_url: String,
    facilitator_token: String,
    max_timeout_seconds: u64,
    resource: Option<String>,
    description: Option<String>,
    mime_type: Option<String>,
}

impl X402Paywall {
    /// Create a new paywall instance.
    pub fn new(opts: PaywallOptions) -> Self {
        Self {
            wallet_address: opts.wallet_address,
            amount_base_units: format!("{}", (opts.amount_usdc * 1_000_000.0).round() as u64),
            network: opts.network,
            asset: opts.asset,
            facilitator_url: opts
                .facilitator_url
                .unwrap_or_else(|| "https://remit.md".to_string())
                .trim_end_matches('/')
                .to_string(),
            facilitator_token: opts.facilitator_token.unwrap_or_default(),
            max_timeout_seconds: opts.max_timeout_seconds.unwrap_or(60),
            resource: opts.resource,
            description: opts.description,
            mime_type: opts.mime_type,
        }
    }

    /// Return the base64-encoded JSON `PAYMENT-REQUIRED` header value.
    pub fn payment_required_header(&self) -> String {
        let mut payload = serde_json::json!({
            "scheme": "exact",
            "network": &self.network,
            "amount": &self.amount_base_units,
            "asset": &self.asset,
            "payTo": &self.wallet_address,
            "maxTimeoutSeconds": self.max_timeout_seconds,
        });
        if let Some(ref r) = self.resource {
            payload["resource"] = serde_json::json!(r);
        }
        if let Some(ref d) = self.description {
            payload["description"] = serde_json::json!(d);
        }
        if let Some(ref m) = self.mime_type {
            payload["mimeType"] = serde_json::json!(m);
        }
        use base64::Engine;
        base64::engine::general_purpose::STANDARD.encode(serde_json::to_string(&payload).unwrap())
    }

    /// Check whether a `PAYMENT-SIGNATURE` header represents a valid payment.
    ///
    /// Calls the remit.md facilitator's `/api/v1/x402/verify` endpoint.
    pub async fn check(&self, payment_sig: Option<&str>) -> CheckResult {
        let sig = match payment_sig {
            Some(s) if !s.is_empty() => s,
            _ => return CheckResult { is_valid: false, invalid_reason: None },
        };

        use base64::Engine;
        let payment_payload: serde_json::Value = match base64::engine::general_purpose::STANDARD
            .decode(sig)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
        {
            Some(v) => v,
            None => {
                return CheckResult {
                    is_valid: false,
                    invalid_reason: Some("INVALID_PAYLOAD".to_string()),
                }
            }
        };

        let payment_required = serde_json::json!({
            "scheme": "exact",
            "network": &self.network,
            "amount": &self.amount_base_units,
            "asset": &self.asset,
            "payTo": &self.wallet_address,
            "maxTimeoutSeconds": self.max_timeout_seconds,
        });

        let body = serde_json::json!({
            "paymentPayload": payment_payload,
            "paymentRequired": payment_required,
        });

        let client = reqwest::Client::new();
        let mut req = client
            .post(format!("{}/api/v1/x402/verify", self.facilitator_url))
            .header("Content-Type", "application/json")
            .json(&body);

        if !self.facilitator_token.is_empty() {
            req = req.header("Authorization", format!("Bearer {}", self.facilitator_token));
        }

        match req.send().await {
            Ok(resp) if resp.status().is_success() => {
                match resp.json::<serde_json::Value>().await {
                    Ok(data) => CheckResult {
                        is_valid: data.get("isValid").and_then(|v| v.as_bool()).unwrap_or(false),
                        invalid_reason: data
                            .get("invalidReason")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string()),
                    },
                    Err(_) => CheckResult {
                        is_valid: false,
                        invalid_reason: Some("FACILITATOR_ERROR".to_string()),
                    },
                }
            }
            _ => CheckResult {
                is_valid: false,
                invalid_reason: Some("FACILITATOR_ERROR".to_string()),
            },
        }
    }
}

// ─── EIP-712 helpers ─────────────────────────────────────────────────────────

use sha3::{Digest, Keccak256};

fn eip712_domain_separator(chain_id: u64, usdc_address: &str) -> [u8; 32] {
    // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    let type_hash = Keccak256::digest(
        b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
    );
    let name_hash = Keccak256::digest(b"USD Coin");
    let version_hash = Keccak256::digest(b"2");

    let mut chain_bytes = [0u8; 32];
    chain_bytes[24..32].copy_from_slice(&chain_id.to_be_bytes());

    let addr_bytes = parse_address(usdc_address);
    let mut addr_padded = [0u8; 32];
    addr_padded[12..32].copy_from_slice(&addr_bytes);

    let mut data = Vec::with_capacity(160);
    data.extend_from_slice(&type_hash);
    data.extend_from_slice(&name_hash);
    data.extend_from_slice(&version_hash);
    data.extend_from_slice(&chain_bytes);
    data.extend_from_slice(&addr_padded);

    Keccak256::digest(&data).into()
}

fn eip3009_struct_hash(
    from: &str,
    to: &str,
    value: u64,
    valid_after: u64,
    valid_before: u64,
    nonce: &[u8; 32],
) -> [u8; 32] {
    // keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    let type_hash = Keccak256::digest(
        b"TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)",
    );

    let from_bytes = parse_address(from);
    let mut from_padded = [0u8; 32];
    from_padded[12..32].copy_from_slice(&from_bytes);

    let to_bytes = parse_address(to);
    let mut to_padded = [0u8; 32];
    to_padded[12..32].copy_from_slice(&to_bytes);

    let mut value_bytes = [0u8; 32];
    value_bytes[24..32].copy_from_slice(&value.to_be_bytes());

    let mut valid_after_bytes = [0u8; 32];
    valid_after_bytes[24..32].copy_from_slice(&valid_after.to_be_bytes());

    let mut valid_before_bytes = [0u8; 32];
    valid_before_bytes[24..32].copy_from_slice(&valid_before.to_be_bytes());

    let mut data = Vec::with_capacity(224);
    data.extend_from_slice(&type_hash);
    data.extend_from_slice(&from_padded);
    data.extend_from_slice(&to_padded);
    data.extend_from_slice(&value_bytes);
    data.extend_from_slice(&valid_after_bytes);
    data.extend_from_slice(&valid_before_bytes);
    data.extend_from_slice(nonce);

    Keccak256::digest(&data).into()
}

fn eip712_digest(domain_separator: &[u8; 32], struct_hash: &[u8; 32]) -> [u8; 32] {
    let mut data = Vec::with_capacity(66);
    data.extend_from_slice(b"\x19\x01");
    data.extend_from_slice(domain_separator);
    data.extend_from_slice(struct_hash);
    Keccak256::digest(&data).into()
}

fn parse_address(addr: &str) -> [u8; 20] {
    let hex_str = addr.strip_prefix("0x").or_else(|| addr.strip_prefix("0X")).unwrap_or(addr);
    let mut out = [0u8; 20];
    if let Ok(bytes) = hex::decode(hex_str) {
        if bytes.len() == 20 {
            out.copy_from_slice(&bytes);
        }
    }
    out
}
