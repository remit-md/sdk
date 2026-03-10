use async_trait::async_trait;
use serde_json::Value;
use std::sync::Arc;

use crate::error::{codes, remit_err, RemitError};
use crate::signer::Signer;

/// Chain configuration: chain ID and API base URL.
#[derive(Debug, Clone)]
pub(crate) struct ChainConfig {
    pub chain_id: u64,
    pub api_url: &'static str,
    #[allow(dead_code)]
    pub testnet: bool,
}

/// All supported chains.
pub(crate) fn chain_config(chain_key: &str) -> Option<ChainConfig> {
    match chain_key {
        "base" => Some(ChainConfig {
            chain_id: 8453,
            api_url: "https://api.remit.md",
            testnet: false,
        }),
        "base-sepolia" => Some(ChainConfig {
            chain_id: 84532,
            api_url: "https://testnet.remit.md",
            testnet: true,
        }),
        "arbitrum" => Some(ChainConfig {
            chain_id: 42161,
            api_url: "https://arb.remit.md",
            testnet: false,
        }),
        "optimism" => Some(ChainConfig {
            chain_id: 10,
            api_url: "https://op.remit.md",
            testnet: false,
        }),
        _ => None,
    }
}

/// Internal transport trait — real HTTP or mock.
#[async_trait]
pub(crate) trait Transport: Send + Sync {
    async fn post(&self, path: &str, body: Option<Value>) -> Result<Value, RemitError>;
    async fn get(&self, path: &str) -> Result<Value, RemitError>;
}

// ─── Real HTTP transport ──────────────────────────────────────────────────────

const DEFAULT_TIMEOUT_SECS: u64 = 30;
const MAX_RETRIES: u32 = 3;

/// Authenticated reqwest-based HTTP client.
pub(crate) struct HttpTransport {
    client: reqwest::Client,
    base_url: String,
    signer: Arc<dyn Signer>,
}

impl HttpTransport {
    pub(crate) fn new(base_url: impl Into<String>, signer: Arc<dyn Signer>) -> Self {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(DEFAULT_TIMEOUT_SECS))
            .build()
            .expect("reqwest client build should not fail");

        Self {
            client,
            base_url: base_url.into(),
            signer,
        }
    }
}

#[async_trait]
impl Transport for HttpTransport {
    async fn post(&self, path: &str, body: Option<Value>) -> Result<Value, RemitError> {
        self.do_request("POST", path, body).await
    }

    async fn get(&self, path: &str) -> Result<Value, RemitError> {
        self.do_request("GET", path, None).await
    }
}

impl HttpTransport {
    async fn do_request(
        &self,
        method: &str,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, RemitError> {
        let url = format!("{}{}", self.base_url, path);
        let mut last_err: Option<RemitError> = None;

        for attempt in 0..MAX_RETRIES {
            if attempt > 0 {
                let delay_ms = 500u64 * (1 << (attempt - 1));
                tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
            }

            match self.attempt(method, &url, body.clone()).await {
                Ok(v) => return Ok(v),
                Err(e) => {
                    // Only retry on rate limit and server errors.
                    let retryable = e.code == codes::RATE_LIMITED || e.code == codes::SERVER_ERROR;
                    last_err = Some(e);
                    if !retryable {
                        break;
                    }
                }
            }
        }

        Err(last_err.unwrap_or_else(|| remit_err(codes::NETWORK_ERROR, "request failed")))
    }

    async fn attempt(
        &self,
        method: &str,
        url: &str,
        body: Option<Value>,
    ) -> Result<Value, RemitError> {
        // Generate a random nonce for replay protection.
        let nonce = {
            let bytes: [u8; 16] = rand_bytes();
            hex::encode(bytes)
        };

        let mut req = if method == "POST" {
            self.client
                .post(url)
                .header("Content-Type", "application/json")
        } else {
            self.client.get(url)
        };

        req = req
            .header("Accept", "application/json")
            .header("X-Remit-Address", self.signer.address())
            .header("X-Remit-Nonce", &nonce);

        if let Some(body) = body {
            req = req.json(&body);
        }

        let resp = req.send().await.map_err(|e| {
            remit_err(
                codes::NETWORK_ERROR,
                format!("request to {url} failed: {e}. Check network connectivity."),
            )
        })?;

        let status = resp.status().as_u16();
        let body_bytes = resp
            .bytes()
            .await
            .map_err(|_| remit_err(codes::NETWORK_ERROR, "failed to read response body"))?;

        if status >= 400 {
            return Err(parse_api_error(status, &body_bytes));
        }

        if body_bytes.is_empty() {
            return Ok(Value::Null);
        }

        serde_json::from_slice(&body_bytes).map_err(|e| {
            remit_err(
                codes::SERVER_ERROR,
                format!("unexpected response format: {e}"),
            )
        })
    }
}

fn parse_api_error(status: u16, body: &[u8]) -> RemitError {
    #[derive(serde::Deserialize)]
    struct ApiErr {
        code: Option<String>,
        message: Option<String>,
    }

    if let Ok(e) = serde_json::from_slice::<ApiErr>(body) {
        if let (Some(code), Some(message)) = (e.code, e.message) {
            return RemitError::new(&code, message);
        }
    }

    if status == 429 {
        return remit_err(
            codes::RATE_LIMITED,
            "rate limit exceeded — reduce request frequency",
        );
    }
    if status >= 500 {
        return remit_err(codes::SERVER_ERROR, format!("server error (HTTP {status})"));
    }
    let preview = String::from_utf8_lossy(&body[..body.len().min(200)]);
    remit_err(
        codes::SERVER_ERROR,
        format!("unexpected error (HTTP {status}): {preview}"),
    )
}

fn rand_bytes<const N: usize>() -> [u8; N] {
    let mut out = [0u8; N];
    getrandom::getrandom(&mut out).expect("getrandom failed: system CSPRNG unavailable");
    out
}
