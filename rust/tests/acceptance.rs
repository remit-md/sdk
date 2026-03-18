//! Rust SDK acceptance tests: payDirect + escrow lifecycle on live Base Sepolia.
//!
//! Run: cargo test --test acceptance -- --include-ignored --nocapture
//!
//! Env vars (all optional):
//!   ACCEPTANCE_API_URL  — default: https://remit.md
//!   ACCEPTANCE_RPC_URL  — default: https://sepolia.base.org

use k256::ecdsa::SigningKey;
use remitmd::{PermitSignature, Wallet};
use rust_decimal::Decimal;
use sha3::{Digest, Keccak256};
use std::env;
use std::str::FromStr;
use std::time::{SystemTime, UNIX_EPOCH};

// ─── Config ──────────────────────────────────────────────────────────────────

fn api_url() -> String {
    env::var("ACCEPTANCE_API_URL").unwrap_or_else(|_| "https://remit.md".to_string())
}

fn rpc_url() -> String {
    env::var("ACCEPTANCE_RPC_URL").unwrap_or_else(|_| "https://sepolia.base.org".to_string())
}

const USDC_ADDRESS: &str = "0x142aD61B8d2edD6b3807D9266866D97C35Ee0317";
const FEE_WALLET: &str = "0xd3f721BDF92a2bB5Dd8d2FE2AFC03aFE5629B420";
const CHAIN_ID: u64 = 84532;

// ─── Contract discovery (unauthenticated) ────────────────────────────────────

#[derive(serde::Deserialize)]
struct Contracts {
    router: String,
    escrow: String,
}

async fn fetch_contracts() -> Contracts {
    let url = format!("{}/api/v0/contracts", api_url());
    let resp = reqwest::get(&url).await.expect("GET /contracts");
    resp.json::<Contracts>().await.expect("parse /contracts")
}

// ─── Wallet creation ─────────────────────────────────────────────────────────

struct TestWallet {
    wallet: Wallet,
    signing_key: SigningKey,
}

fn create_test_wallet(router: &str) -> TestWallet {
    let signing_key = SigningKey::random(&mut rand_core::OsRng);
    let hex_key = format!("0x{}", hex::encode(signing_key.to_bytes()));

    let wallet = Wallet::new(&hex_key)
        .testnet()
        .base_url(&api_url())
        .router_address(router)
        .build()
        .expect("build wallet");

    TestWallet {
        wallet,
        signing_key,
    }
}

// ─── On-chain balance via RPC ────────────────────────────────────────────────

async fn get_usdc_balance(address: &str) -> f64 {
    let addr_hex = address.trim_start_matches("0x").to_lowercase();
    let padded = format!("{:0>64}", addr_hex);
    let data = format!("0x70a08231{padded}");

    let client = reqwest::Client::new();
    let resp = client
        .post(&rpc_url())
        .json(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_call",
            "params": [{ "to": USDC_ADDRESS, "data": data }, "latest"],
        }))
        .send()
        .await
        .expect("RPC balanceOf");

    let body: serde_json::Value = resp.json().await.expect("parse RPC response");
    if let Some(err) = body.get("error") {
        panic!("RPC error: {}", err);
    }
    let hex_str = body["result"].as_str().unwrap_or("0x0");
    let val = u128::from_str_radix(hex_str.trim_start_matches("0x"), 16).unwrap_or(0);
    val as f64 / 1e6
}

async fn get_fee_balance() -> f64 {
    get_usdc_balance(FEE_WALLET).await
}

async fn wait_for_balance_change(address: &str, before: f64) -> f64 {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while std::time::Instant::now() < deadline {
        let current = get_usdc_balance(address).await;
        if (current - before).abs() > 0.0001 {
            return current;
        }
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
    get_usdc_balance(address).await
}

fn assert_balance_change(label: &str, before: f64, after: f64, expected: f64) {
    let actual = after - before;
    // Use max of 10 bps OR $0.02 absolute tolerance (handles concurrent test fee noise).
    let tolerance = (expected.abs() * 0.001).max(0.02);
    let diff = (actual - expected).abs();
    assert!(
        diff <= tolerance,
        "{label}: expected delta {expected:.6}, got {actual:.6} (before={before:.6}, after={after:.6})"
    );
}

// ─── Funding ─────────────────────────────────────────────────────────────────

async fn fund_wallet(w: &TestWallet, amount: f64) {
    w.wallet.mint(amount).await.expect("mint");
    wait_for_balance_change(w.wallet.address(), 0.0).await;
}

// ─── EIP-2612 Permit Signing ─────────────────────────────────────────────────

fn keccak256(data: &[u8]) -> [u8; 32] {
    let mut h = Keccak256::new();
    h.update(data);
    h.finalize().into()
}

fn pad_address(addr: &str) -> [u8; 32] {
    let hex_str = addr.trim_start_matches("0x");
    let bytes = hex::decode(hex_str).expect("decode address");
    let mut padded = [0u8; 32];
    if bytes.len() == 20 {
        padded[12..].copy_from_slice(&bytes);
    }
    padded
}

fn pad_u256(val: u64) -> [u8; 32] {
    let mut padded = [0u8; 32];
    padded[24..].copy_from_slice(&val.to_be_bytes());
    padded
}

fn sign_usdc_permit(
    key: &SigningKey,
    owner: &str,
    spender: &str,
    value: u64,
    nonce: u64,
    deadline: u64,
) -> PermitSignature {
    // Domain separator for USDC EIP-2612
    let domain_type_hash = keccak256(
        b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
    );
    let name_hash = keccak256(b"USD Coin");
    let version_hash = keccak256(b"2");

    let usdc_hex = USDC_ADDRESS.trim_start_matches("0x");
    let usdc_bytes = hex::decode(usdc_hex).expect("decode USDC address");
    let mut usdc_padded = [0u8; 32];
    usdc_padded[12..].copy_from_slice(&usdc_bytes);

    let mut domain_data = [0u8; 160];
    domain_data[0..32].copy_from_slice(&domain_type_hash);
    domain_data[32..64].copy_from_slice(&name_hash);
    domain_data[64..96].copy_from_slice(&version_hash);
    domain_data[96..128].copy_from_slice(&pad_u256(CHAIN_ID));
    domain_data[128..160].copy_from_slice(&usdc_padded);
    let domain_sep = keccak256(&domain_data);

    // Permit struct hash
    let permit_type_hash = keccak256(
        b"Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)",
    );

    let mut struct_data = [0u8; 192]; // 6 × 32
    struct_data[0..32].copy_from_slice(&permit_type_hash);
    struct_data[32..64].copy_from_slice(&pad_address(owner));
    struct_data[64..96].copy_from_slice(&pad_address(spender));
    struct_data[96..128].copy_from_slice(&pad_u256(value));
    struct_data[128..160].copy_from_slice(&pad_u256(nonce));
    struct_data[160..192].copy_from_slice(&pad_u256(deadline));
    let struct_hash = keccak256(&struct_data);

    // EIP-712 digest
    let mut final_data = [0u8; 66];
    final_data[0] = 0x19;
    final_data[1] = 0x01;
    final_data[2..34].copy_from_slice(&domain_sep);
    final_data[34..66].copy_from_slice(&struct_hash);
    let digest = keccak256(&final_data);

    // Sign with k256
    let (sig, recovery_id) = key.sign_prehash_recoverable(&digest).expect("sign permit");
    let sig_bytes = sig.to_bytes();
    let v = recovery_id.to_byte() + 27;

    PermitSignature {
        value,
        deadline,
        v,
        r: format!("0x{}", hex::encode(&sig_bytes[..32])),
        s: format!("0x{}", hex::encode(&sig_bytes[32..])),
    }
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_pay_direct_with_permit() {
    let contracts = fetch_contracts().await;

    let agent = create_test_wallet(&contracts.router);
    let provider = create_test_wallet(&contracts.router);
    fund_wallet(&agent, 100.0).await;

    let amount = 1.0;
    let fee = 0.01;
    let provider_receives = amount - fee;

    let agent_before = get_usdc_balance(agent.wallet.address()).await;
    let provider_before = get_usdc_balance(provider.wallet.address()).await;
    let fee_before = get_fee_balance().await;

    // Sign EIP-2612 permit for Router
    let permit = sign_usdc_permit(
        &agent.signing_key,
        agent.wallet.address(),
        &contracts.router,
        2_000_000, // $2 USDC in base units
        0,         // nonce 0
        now_unix() + 3600,
    );

    let tx = agent
        .wallet
        .pay_full(
            provider.wallet.address(),
            Decimal::from_str("1.0").unwrap(),
            "rust-sdk-acceptance",
            Some(permit),
        )
        .await
        .expect("pay_full");
    assert!(
        tx.tx_hash.starts_with("0x"),
        "expected tx hash starting with 0x, got: {}",
        tx.tx_hash
    );

    let agent_after = wait_for_balance_change(agent.wallet.address(), agent_before).await;
    let provider_after = get_usdc_balance(provider.wallet.address()).await;
    let fee_after = get_fee_balance().await;

    assert_balance_change("agent", agent_before, agent_after, -amount);
    assert_balance_change(
        "provider",
        provider_before,
        provider_after,
        provider_receives,
    );
    assert_balance_change("fee wallet", fee_before, fee_after, fee);
}

#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_escrow_lifecycle() {
    let contracts = fetch_contracts().await;

    let agent = create_test_wallet(&contracts.router);
    let provider = create_test_wallet(&contracts.router);
    fund_wallet(&agent, 100.0).await;

    let amount = 5.0;
    let fee = amount * 0.01;
    let provider_receives = amount - fee;

    let agent_before = get_usdc_balance(agent.wallet.address()).await;
    let provider_before = get_usdc_balance(provider.wallet.address()).await;
    let fee_before = get_fee_balance().await;

    // Sign EIP-2612 permit for Escrow contract
    let permit = sign_usdc_permit(
        &agent.signing_key,
        agent.wallet.address(),
        &contracts.escrow,
        6_000_000, // $6 USDC
        0,
        now_unix() + 3600,
    );

    let escrow = agent
        .wallet
        .create_escrow_with_permit(
            provider.wallet.address(),
            Decimal::from_str("5.0").unwrap(),
            permit,
        )
        .await
        .expect("create_escrow_with_permit");
    assert!(!escrow.id.is_empty(), "escrow should have an id");

    // Wait for on-chain lock
    wait_for_balance_change(agent.wallet.address(), agent_before).await;

    // Provider claims start
    provider
        .wallet
        .claim_start(&escrow.id)
        .await
        .expect("claim_start");
    tokio::time::sleep(std::time::Duration::from_secs(5)).await;

    // Agent releases
    agent
        .wallet
        .release_escrow(&escrow.id, None)
        .await
        .expect("release_escrow");

    // Verify balances
    let provider_after = wait_for_balance_change(provider.wallet.address(), provider_before).await;
    let fee_after = get_fee_balance().await;
    let agent_after = get_usdc_balance(agent.wallet.address()).await;

    assert_balance_change("agent", agent_before, agent_after, -amount);
    assert_balance_change(
        "provider",
        provider_before,
        provider_after,
        provider_receives,
    );
    assert_balance_change("fee wallet", fee_before, fee_after, fee);
}
