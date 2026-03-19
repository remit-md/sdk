use async_trait::async_trait;
use serde_json::Value;
use sha3::{Digest, Keccak256};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::error::{codes, remit_err, RemitError};
use crate::signer::Signer;

// ─── Chain constants ─────────────────────────────────────────────────────────

/// Known USDC contract addresses per chain key.
pub(crate) const USDC_ADDRESSES: &[(&str, &str)] = &[
    ("base-sepolia", "0x142aD61B8d2edD6b3807D9266866D97C35Ee0317"),
    ("base", "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"),
    ("localhost", "0x5FbDB2315678afecb367f032d93F642f64180aa3"),
];

/// Default public RPC URLs per chain key.
pub(crate) const DEFAULT_RPC_URLS: &[(&str, &str)] = &[
    ("base-sepolia", "https://sepolia.base.org"),
    ("base", "https://mainnet.base.org"),
    ("localhost", "http://127.0.0.1:8545"),
];

/// Look up a USDC address by chain key (e.g. "base-sepolia").
pub(crate) fn usdc_address(chain_key: &str) -> Option<&'static str> {
    USDC_ADDRESSES
        .iter()
        .find(|(k, _)| *k == chain_key)
        .map(|(_, v)| *v)
}

/// Look up a default RPC URL by chain key.
pub(crate) fn default_rpc_url(chain_key: &str) -> Option<&'static str> {
    DEFAULT_RPC_URLS
        .iter()
        .find(|(k, _)| *k == chain_key)
        .map(|(_, v)| *v)
}

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
    chain_id: u64,
    router_address: String,
    signer: Arc<dyn Signer>,
}

impl HttpTransport {
    pub(crate) fn new(
        base_url: impl Into<String>,
        chain_id: u64,
        router_address: impl Into<String>,
        signer: Arc<dyn Signer>,
    ) -> Self {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(DEFAULT_TIMEOUT_SECS))
            .build()
            .expect("reqwest client build should not fail");

        Self {
            client,
            base_url: base_url.into(),
            chain_id,
            router_address: router_address.into(),
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

            match self.attempt(method, &url, path, body.clone()).await {
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
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, RemitError> {
        // Generate a random 32-byte nonce for replay protection.
        let nonce_bytes: [u8; 32] = rand_bytes();
        let nonce_hex = format!("0x{}", hex::encode(nonce_bytes));

        // Current Unix timestamp in seconds.
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        // Compute EIP-712 hash and sign it.
        let digest = compute_eip712_hash(
            self.chain_id,
            &self.router_address,
            method,
            path,
            timestamp,
            &nonce_bytes,
        );
        let sig = self.signer.sign(&digest)?;
        let sig_hex = format!("0x{}", hex::encode(&sig));

        let mut req = if method == "POST" {
            self.client
                .post(url)
                .header("Content-Type", "application/json")
        } else {
            self.client.get(url)
        };

        req = req
            .header("Accept", "application/json")
            .header("X-Remit-Agent", self.signer.address())
            .header("X-Remit-Nonce", &nonce_hex)
            .header("X-Remit-Timestamp", timestamp.to_string())
            .header("X-Remit-Signature", &sig_hex);

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

// ─── EIP-712 ──────────────────────────────────────────────────────────────────

fn keccak256_hash(data: &[u8]) -> [u8; 32] {
    let mut h = Keccak256::new();
    h.update(data);
    h.finalize().into()
}

/// Compute the EIP-712 hash for an APIRequest struct.
///
/// Domain: name="remit.md", version="0.1", chainId, verifyingContract
/// Struct: APIRequest(string method, string path, uint256 timestamp, bytes32 nonce)
pub(crate) fn compute_eip712_hash(
    chain_id: u64,
    router_address: &str,
    method: &str,
    path: &str,
    timestamp: u64,
    nonce: &[u8; 32],
) -> [u8; 32] {
    // Type hashes.
    let domain_type_hash = keccak256_hash(
        b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
    );
    let request_type_hash =
        keccak256_hash(b"APIRequest(string method,string path,uint256 timestamp,bytes32 nonce)");

    // Domain separator components.
    let name_hash = keccak256_hash(b"remit.md");
    let version_hash = keccak256_hash(b"0.1");

    let mut chain_id_padded = [0u8; 32];
    chain_id_padded[24..].copy_from_slice(&chain_id.to_be_bytes());

    // Parse verifying contract address → 32 bytes (left-zero-padded).
    let addr_hex = router_address.trim_start_matches("0x");
    let addr_bytes = hex::decode(addr_hex).unwrap_or_default();
    let mut addr_padded = [0u8; 32];
    if addr_bytes.len() == 20 {
        addr_padded[12..].copy_from_slice(&addr_bytes);
    }

    let mut domain_data = [0u8; 160]; // 5 × 32
    domain_data[0..32].copy_from_slice(&domain_type_hash);
    domain_data[32..64].copy_from_slice(&name_hash);
    domain_data[64..96].copy_from_slice(&version_hash);
    domain_data[96..128].copy_from_slice(&chain_id_padded);
    domain_data[128..160].copy_from_slice(&addr_padded);
    let domain_separator = keccak256_hash(&domain_data);

    // Struct hash.
    let method_hash = keccak256_hash(method.as_bytes());
    let path_hash = keccak256_hash(path.as_bytes());

    let mut timestamp_padded = [0u8; 32];
    timestamp_padded[24..].copy_from_slice(&timestamp.to_be_bytes());

    let mut struct_data = [0u8; 160]; // 5 × 32
    struct_data[0..32].copy_from_slice(&request_type_hash);
    struct_data[32..64].copy_from_slice(&method_hash);
    struct_data[64..96].copy_from_slice(&path_hash);
    struct_data[96..128].copy_from_slice(&timestamp_padded);
    struct_data[128..160].copy_from_slice(nonce);
    let struct_hash = keccak256_hash(&struct_data);

    // EIP-712 final hash: "\x19\x01" || domainSeparator || structHash
    let mut final_data = [0u8; 66];
    final_data[0] = 0x19;
    final_data[1] = 0x01;
    final_data[2..34].copy_from_slice(&domain_separator);
    final_data[34..66].copy_from_slice(&struct_hash);
    keccak256_hash(&final_data)
}

/// Compute the EIP-712 hash for an ERC-2612 Permit struct.
///
/// Domain: name="USD Coin", version="2", chainId, verifyingContract=usdcAddr
/// Struct: Permit(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
pub(crate) fn compute_permit_digest(
    chain_id: u64,
    usdc_addr: &str,
    owner: &str,
    spender: &str,
    value: u64,
    nonce: u64,
    deadline: u64,
) -> [u8; 32] {
    // Type hashes.
    let domain_type_hash = keccak256_hash(
        b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
    );
    let permit_type_hash = keccak256_hash(
        b"Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)",
    );

    // Domain separator components.
    let name_hash = keccak256_hash(b"USD Coin");
    let version_hash = keccak256_hash(b"2");

    let mut chain_id_padded = [0u8; 32];
    chain_id_padded[24..].copy_from_slice(&chain_id.to_be_bytes());

    // Parse USDC contract address → 32 bytes (left-zero-padded).
    let usdc_hex = usdc_addr.trim_start_matches("0x");
    let usdc_bytes = hex::decode(usdc_hex).unwrap_or_default();
    let mut usdc_padded = [0u8; 32];
    if usdc_bytes.len() == 20 {
        usdc_padded[12..].copy_from_slice(&usdc_bytes);
    }

    let mut domain_data = [0u8; 160]; // 5 × 32
    domain_data[0..32].copy_from_slice(&domain_type_hash);
    domain_data[32..64].copy_from_slice(&name_hash);
    domain_data[64..96].copy_from_slice(&version_hash);
    domain_data[96..128].copy_from_slice(&chain_id_padded);
    domain_data[128..160].copy_from_slice(&usdc_padded);
    let domain_separator = keccak256_hash(&domain_data);

    // Struct hash: Permit(owner, spender, value, nonce, deadline).
    let owner_hex = owner.trim_start_matches("0x");
    let owner_bytes = hex::decode(owner_hex).unwrap_or_default();
    let mut owner_padded = [0u8; 32];
    if owner_bytes.len() == 20 {
        owner_padded[12..].copy_from_slice(&owner_bytes);
    }

    let spender_hex = spender.trim_start_matches("0x");
    let spender_bytes = hex::decode(spender_hex).unwrap_or_default();
    let mut spender_padded = [0u8; 32];
    if spender_bytes.len() == 20 {
        spender_padded[12..].copy_from_slice(&spender_bytes);
    }

    // uint256 encoding: value, nonce, deadline — each as 32-byte big-endian.
    let mut value_padded = [0u8; 32];
    value_padded[24..].copy_from_slice(&value.to_be_bytes());

    let mut nonce_padded = [0u8; 32];
    nonce_padded[24..].copy_from_slice(&nonce.to_be_bytes());

    let mut deadline_padded = [0u8; 32];
    deadline_padded[24..].copy_from_slice(&deadline.to_be_bytes());

    let mut struct_data = [0u8; 192]; // 6 × 32
    struct_data[0..32].copy_from_slice(&permit_type_hash);
    struct_data[32..64].copy_from_slice(&owner_padded);
    struct_data[64..96].copy_from_slice(&spender_padded);
    struct_data[96..128].copy_from_slice(&value_padded);
    struct_data[128..160].copy_from_slice(&nonce_padded);
    struct_data[160..192].copy_from_slice(&deadline_padded);
    let struct_hash = keccak256_hash(&struct_data);

    // EIP-712 final hash: "\x19\x01" || domainSeparator || structHash
    let mut final_data = [0u8; 66];
    final_data[0] = 0x19;
    final_data[1] = 0x01;
    final_data[2..34].copy_from_slice(&domain_separator);
    final_data[34..66].copy_from_slice(&struct_hash);
    keccak256_hash(&final_data)
}

/// Fetch the ERC-2612 nonce for `owner` from the USDC contract via JSON-RPC `eth_call`.
///
/// Calls `nonces(address)` (selector `0x7ecebe00`) on the USDC contract.
pub(crate) async fn fetch_usdc_nonce(
    rpc_url: &str,
    usdc_addr: &str,
    owner: &str,
) -> Result<u64, RemitError> {
    let padded_owner = format!(
        "{:0>64}",
        owner.trim_start_matches("0x").to_lowercase()
    );
    let data = format!("0x7ecebe00{padded_owner}");

    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_call",
        "params": [
            { "to": usdc_addr, "data": data },
            "latest"
        ]
    });

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| {
            remit_err(
                codes::NETWORK_ERROR,
                format!("HTTP client build failed: {e}"),
            )
        })?;

    let resp = client
        .post(rpc_url)
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| {
            remit_err(
                codes::NETWORK_ERROR,
                format!("RPC request to {rpc_url} failed: {e}"),
            )
        })?;

    let json: Value = resp.json().await.map_err(|e| {
        remit_err(
            codes::NETWORK_ERROR,
            format!("failed to parse RPC response: {e}"),
        )
    })?;

    if let Some(err) = json.get("error") {
        return Err(remit_err(
            codes::SERVER_ERROR,
            format!("RPC error: {err}"),
        ));
    }

    let result_hex = json["result"]
        .as_str()
        .ok_or_else(|| remit_err(codes::SERVER_ERROR, "RPC response missing result field"))?;

    // Parse the hex result (0x-prefixed, 32-byte big-endian uint256) into u64.
    let hex_str = result_hex.trim_start_matches("0x");
    u64::from_str_radix(hex_str, 16).map_err(|e| {
        remit_err(
            codes::SERVER_ERROR,
            format!("failed to parse nonce from RPC result {result_hex}: {e}"),
        )
    })
}

// ─── Error parsing ────────────────────────────────────────────────────────────

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

// ─── Golden vector tests ──────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::signer::PrivateKeySigner;
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct GvDomain {
        #[serde(rename = "chain_id")]
        chain_id: u64,
        #[serde(rename = "verifying_contract")]
        verifying_contract: String,
    }

    #[derive(Deserialize)]
    struct GvMessage {
        method: String,
        path: String,
        timestamp: u64,
        nonce: String,
    }

    #[derive(Deserialize)]
    struct GvVector {
        description: String,
        domain: GvDomain,
        message: GvMessage,
        expected_hash: String,
        expected_signature: String,
    }

    #[derive(Deserialize)]
    struct GvFile {
        vectors: Vec<GvVector>,
    }

    fn load_vectors() -> Vec<GvVector> {
        let data = std::fs::read_to_string("../test-vectors/eip712.json")
            .expect("read ../test-vectors/eip712.json — run `cargo run --bin gen_vectors` first");
        let f: GvFile = serde_json::from_str(&data).expect("parse test vectors");
        assert!(!f.vectors.is_empty(), "vectors array must not be empty");
        f.vectors
    }

    fn parse_nonce(s: &str) -> [u8; 32] {
        let hex = s.trim_start_matches("0x");
        let bytes = hex::decode(hex).expect("valid hex nonce");
        assert_eq!(bytes.len(), 32, "nonce must be 32 bytes");
        bytes.try_into().unwrap()
    }

    #[test]
    fn golden_vectors_hash() {
        let vectors = load_vectors();
        for v in &vectors {
            let nonce = parse_nonce(&v.message.nonce);
            let got = compute_eip712_hash(
                v.domain.chain_id,
                &v.domain.verifying_contract,
                &v.message.method,
                &v.message.path,
                v.message.timestamp,
                &nonce,
            );
            let got_hex = format!("0x{}", hex::encode(got));
            assert_eq!(
                got_hex, v.expected_hash,
                "EIP-712 hash mismatch for {:?}",
                v.description
            );
        }
    }

    #[test]
    fn golden_vectors_signature() {
        // Anvil test wallet #0 — same key used by gen_vectors in remit-server.
        const TEST_PRIV_KEY: &str =
            "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
        let signer = PrivateKeySigner::new(TEST_PRIV_KEY).expect("create signer");

        let vectors = load_vectors();
        for v in &vectors {
            let nonce = parse_nonce(&v.message.nonce);
            let digest = compute_eip712_hash(
                v.domain.chain_id,
                &v.domain.verifying_contract,
                &v.message.method,
                &v.message.path,
                v.message.timestamp,
                &nonce,
            );
            let sig = signer.sign(&digest).expect("sign");
            let got_sig = format!("0x{}", hex::encode(&sig));
            assert_eq!(
                got_sig, v.expected_signature,
                "signature mismatch for {:?}",
                v.description
            );
        }
    }
}
