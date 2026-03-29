//! Rust SDK acceptance tests: all 9 payment flows on live Base Sepolia.
//!
//! Run: cargo test --test acceptance -- --include-ignored --nocapture
//!
//! Env vars (all optional):
//!   ACCEPTANCE_API_URL  - default: https://testnet.remit.md
//!   ACCEPTANCE_RPC_URL  - default: https://sepolia.base.org

use k256::ecdsa::SigningKey;
use remitmd::a2a::{get_task_tx_hash, A2AClient, AgentCard, SendOptions};
use remitmd::{PrivateKeySigner, Wallet};
use rust_decimal::Decimal;
use sha3::{Digest, Keccak256};
use std::env;
use std::str::FromStr;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::OnceCell;

// ─── Config ──────────────────────────────────────────────────────────────────

fn api_url() -> String {
    env::var("ACCEPTANCE_API_URL").unwrap_or_else(|_| "https://testnet.remit.md".to_string())
}

fn rpc_url() -> String {
    env::var("ACCEPTANCE_RPC_URL").unwrap_or_else(|_| "https://sepolia.base.org".to_string())
}

// ─── Contract discovery (unauthenticated) ────────────────────────────────────

#[derive(serde::Deserialize, Clone)]
struct Contracts {
    router: String,
    #[allow(dead_code)]
    escrow: String,
    tab: String,
    #[allow(dead_code)]
    stream: String,
    #[allow(dead_code)]
    bounty: String,
    #[allow(dead_code)]
    deposit: String,
    usdc: String,
    chain_id: u64,
}

async fn fetch_contracts() -> Contracts {
    let url = format!("{}/api/v1/contracts", api_url());
    let resp = reqwest::get(&url).await.expect("GET /contracts");
    resp.json::<Contracts>().await.expect("parse /contracts")
}

// ─── Shared wallets (created once, reused across tests) ─────────────────────

struct SharedWallets {
    agent: TestWallet,
    provider: TestWallet,
    contracts: Contracts,
}

static WALLETS: OnceCell<SharedWallets> = OnceCell::const_new();

async fn get_wallets() -> &'static SharedWallets {
    WALLETS
        .get_or_init(|| async {
            let contracts = fetch_contracts().await;
            let agent = create_test_wallet(&contracts.router);
            let provider = create_test_wallet(&contracts.router);
            fund_wallet(&agent, 100.0, &contracts.usdc).await;
            SharedWallets {
                agent,
                provider,
                contracts,
            }
        })
        .await
}

// ─── Wallet creation ─────────────────────────────────────────────────────────

struct TestWallet {
    wallet: Wallet,
    signing_key: SigningKey,
    hex_key: String,
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

    eprintln!(
        "[ACCEPTANCE] wallet: {} (chain=84532)",
        wallet.address()
    );
    TestWallet {
        wallet,
        signing_key,
        hex_key,
    }
}

// ─── On-chain balance via RPC ────────────────────────────────────────────────

async fn get_usdc_balance(address: &str, usdc_address: &str) -> f64 {
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
            "params": [{ "to": usdc_address, "data": data }, "latest"],
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

async fn wait_for_balance_change(address: &str, before: f64, usdc_address: &str) -> f64 {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while std::time::Instant::now() < deadline {
        let current = get_usdc_balance(address, usdc_address).await;
        if (current - before).abs() > 0.0001 {
            return current;
        }
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
    get_usdc_balance(address, usdc_address).await
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

async fn fund_wallet(w: &TestWallet, amount: f64, usdc_address: &str) {
    eprintln!(
        "[ACCEPTANCE] mint: {} USDC -> {}",
        amount,
        w.wallet.address()
    );
    w.wallet.mint(amount).await.expect("mint");
    wait_for_balance_change(w.wallet.address(), 0.0, usdc_address).await;
}

fn log_tx(flow: &str, step: &str, tx_hash: &str) {
    eprintln!(
        "[ACCEPTANCE] {} | {} | tx={} | https://sepolia.basescan.org/tx/{}",
        flow, step, tx_hash, tx_hash
    );
}

fn keccak256(data: &[u8]) -> [u8; 32] {
    let mut h = Keccak256::new();
    h.update(data);
    h.finalize().into()
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

// ─── EIP-712 TabCharge Signing ───────────────────────────────────────────────

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

/// Sign a TabCharge EIP-712 message for the RemitTab contract.
fn sign_tab_charge(
    key: &SigningKey,
    tab_contract: &str,
    tab_id: &str,
    total_charged: u64,
    call_count: u32,
    chain_id: u64,
) -> String {
    let domain_type_hash = keccak256(
        b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
    );
    let name_hash = keccak256(b"RemitTab");
    let version_hash = keccak256(b"1");

    let mut domain_data = [0u8; 160];
    domain_data[0..32].copy_from_slice(&domain_type_hash);
    domain_data[32..64].copy_from_slice(&name_hash);
    domain_data[64..96].copy_from_slice(&version_hash);
    domain_data[96..128].copy_from_slice(&pad_u256(chain_id));
    domain_data[128..160].copy_from_slice(&pad_address(tab_contract));
    let domain_sep = keccak256(&domain_data);

    let tab_charge_type_hash =
        keccak256(b"TabCharge(bytes32 tabId,uint96 totalCharged,uint32 callCount)");

    let mut tab_id_bytes = [0u8; 32];
    let id_bytes = tab_id.as_bytes();
    let copy_len = id_bytes.len().min(32);
    tab_id_bytes[..copy_len].copy_from_slice(&id_bytes[..copy_len]);

    let total_charged_padded = pad_u256(total_charged);
    let call_count_padded = pad_u256(call_count as u64);

    let mut struct_data = [0u8; 128];
    struct_data[0..32].copy_from_slice(&tab_charge_type_hash);
    struct_data[32..64].copy_from_slice(&tab_id_bytes);
    struct_data[64..96].copy_from_slice(&total_charged_padded);
    struct_data[96..128].copy_from_slice(&call_count_padded);
    let struct_hash = keccak256(&struct_data);

    let mut final_data = [0u8; 66];
    final_data[0] = 0x19;
    final_data[1] = 0x01;
    final_data[2..34].copy_from_slice(&domain_sep);
    final_data[34..66].copy_from_slice(&struct_hash);
    let digest = keccak256(&final_data);

    let (sig, recovery_id) = key
        .sign_prehash_recoverable(&digest)
        .expect("sign tab charge");
    let mut sig_bytes = sig.to_bytes().to_vec();
    sig_bytes.push(recovery_id.to_byte() + 27);

    format!("0x{}", hex::encode(&sig_bytes))
}

// ─── EIP-712 API Auth (for raw HTTP requests) ───────────────────────────────

fn compute_api_eip712_hash(
    chain_id: u64,
    router_address: &str,
    method: &str,
    path: &str,
    timestamp: u64,
    nonce: &[u8; 32],
) -> [u8; 32] {
    let domain_type_hash = keccak256(
        b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
    );
    let name_hash = keccak256(b"remit.md");
    let version_hash = keccak256(b"0.1");

    let mut domain_data = [0u8; 160];
    domain_data[0..32].copy_from_slice(&domain_type_hash);
    domain_data[32..64].copy_from_slice(&name_hash);
    domain_data[64..96].copy_from_slice(&version_hash);
    domain_data[96..128].copy_from_slice(&pad_u256(chain_id));
    domain_data[128..160].copy_from_slice(&pad_address(router_address));
    let domain_sep = keccak256(&domain_data);

    let struct_type_hash = keccak256(
        b"APIRequest(string method,string path,uint256 timestamp,bytes32 nonce)",
    );
    let method_hash = keccak256(method.as_bytes());
    let path_hash = keccak256(path.as_bytes());

    let mut struct_data = [0u8; 160];
    struct_data[0..32].copy_from_slice(&struct_type_hash);
    struct_data[32..64].copy_from_slice(&method_hash);
    struct_data[64..96].copy_from_slice(&path_hash);
    struct_data[96..128].copy_from_slice(&pad_u256(timestamp));
    struct_data[128..160].copy_from_slice(nonce);
    let struct_hash = keccak256(&struct_data);

    let mut final_data = [0u8; 66];
    final_data[0] = 0x19;
    final_data[1] = 0x01;
    final_data[2..34].copy_from_slice(&domain_sep);
    final_data[34..66].copy_from_slice(&struct_hash);
    keccak256(&final_data)
}

/// Make an authenticated POST request using EIP-712 signed headers.
async fn authenticated_post(
    url: &str,
    path: &str,
    body: &serde_json::Value,
    signing_key: &SigningKey,
    address: &str,
    chain_id: u64,
    router_address: &str,
) -> serde_json::Value {
    let nonce: [u8; 32] = rand_bytes();
    let nonce_hex = format!("0x{}", hex::encode(nonce));
    let timestamp = now_unix();

    let digest = compute_api_eip712_hash(chain_id, router_address, "POST", path, timestamp, &nonce);
    let (sig, recovery_id) = signing_key
        .sign_prehash_recoverable(&digest)
        .expect("sign API request");
    let mut sig_bytes = sig.to_bytes().to_vec();
    sig_bytes.push(recovery_id.to_byte() + 27);
    let sig_hex = format!("0x{}", hex::encode(&sig_bytes));

    let client = reqwest::Client::new();
    let resp = client
        .post(url)
        .header("Content-Type", "application/json")
        .header("Accept", "application/json")
        .header("X-Remit-Agent", address)
        .header("X-Remit-Nonce", &nonce_hex)
        .header("X-Remit-Timestamp", timestamp.to_string())
        .header("X-Remit-Signature", &sig_hex)
        .json(body)
        .send()
        .await
        .expect("authenticated POST");

    let status = resp.status().as_u16();
    let text = resp.text().await.expect("read response body");
    assert!(
        status < 400,
        "authenticated POST {path} returned {status}: {text}"
    );
    serde_json::from_str(&text).expect("parse JSON response")
}

fn rand_bytes<const N: usize>() -> [u8; N] {
    let mut buf = [0u8; N];
    getrandom::getrandom(&mut buf).expect("getrandom");
    buf
}

// ─── Tests ───────────────────────────────────────────────────────────────────

// 1. Direct payment
#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_01_direct() {
    let w = get_wallets().await;
    let amount = 1.0;

    let agent_before = get_usdc_balance(w.agent.wallet.address(), &w.contracts.usdc).await;
    let provider_before = get_usdc_balance(w.provider.wallet.address(), &w.contracts.usdc).await;

    let permit = w.agent.wallet.sign_permit("direct", 2.0).await.expect("sign_permit direct");
    let tx = w
        .agent
        .wallet
        .pay_full(
            w.provider.wallet.address(),
            Decimal::from_str("1.0").unwrap(),
            "acceptance-direct",
            Some(permit),
        )
        .await
        .expect("pay_full");

    assert!(tx.tx_hash.starts_with("0x"), "bad tx hash: {}", tx.tx_hash);
    log_tx("direct", &format!("{amount} USDC"), &tx.tx_hash);

    let agent_after =
        wait_for_balance_change(w.agent.wallet.address(), agent_before, &w.contracts.usdc).await;
    let provider_after =
        get_usdc_balance(w.provider.wallet.address(), &w.contracts.usdc).await;

    assert_balance_change("agent", agent_before, agent_after, -amount);
    assert_balance_change("provider", provider_before, provider_after, amount * 0.99);
}

// 2. Escrow lifecycle
#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_02_escrow() {
    let w = get_wallets().await;
    let amount = 2.0;

    let agent_before = get_usdc_balance(w.agent.wallet.address(), &w.contracts.usdc).await;
    let provider_before = get_usdc_balance(w.provider.wallet.address(), &w.contracts.usdc).await;

    let permit = w.agent.wallet.sign_permit("escrow", 3.0).await.expect("sign_permit escrow");
    let escrow = w
        .agent
        .wallet
        .create_escrow_with_permit(
            w.provider.wallet.address(),
            Decimal::from_str("2.0").unwrap(),
            permit,
        )
        .await
        .expect("create_escrow_with_permit");

    assert!(!escrow.id.is_empty(), "escrow should have an id");
    log_tx("escrow", &format!("fund {amount} USDC"), &escrow.tx_hash);

    wait_for_balance_change(w.agent.wallet.address(), agent_before, &w.contracts.usdc).await;

    let claimed = w
        .provider
        .wallet
        .claim_start(&escrow.id)
        .await
        .expect("claim_start");
    log_tx("escrow", "claimStart", &claimed.tx_hash);
    tokio::time::sleep(std::time::Duration::from_secs(5)).await;

    let released = w
        .agent
        .wallet
        .release_escrow(&escrow.id, None)
        .await
        .expect("release_escrow");
    log_tx("escrow", "release", &released.tx_hash);

    let provider_after =
        wait_for_balance_change(w.provider.wallet.address(), provider_before, &w.contracts.usdc)
            .await;
    let agent_after = get_usdc_balance(w.agent.wallet.address(), &w.contracts.usdc).await;

    assert_balance_change("agent", agent_before, agent_after, -amount);
    assert_balance_change("provider", provider_before, provider_after, amount * 0.99);
}

// 3. Tab lifecycle
#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_03_tab() {
    let w = get_wallets().await;
    let limit = 5.0;
    let charge_amount = 1.0;
    let charge_units: u64 = (charge_amount * 1_000_000.0) as u64;

    let agent_before = get_usdc_balance(w.agent.wallet.address(), &w.contracts.usdc).await;
    let provider_before = get_usdc_balance(w.provider.wallet.address(), &w.contracts.usdc).await;

    let permit = w.agent.wallet.sign_permit("tab", limit + 1.0).await.expect("sign_permit tab");
    let tab = w
        .agent
        .wallet
        .create_tab_with_permit(
            w.provider.wallet.address(),
            Decimal::from_str("5.0").unwrap(),
            Decimal::from_str("0.10").unwrap(),
            permit,
        )
        .await
        .expect("create_tab_with_permit");

    assert!(!tab.id.is_empty(), "tab ID should not be empty");
    log_tx("tab", &format!("open limit={limit}"), &tab.tx_hash);

    wait_for_balance_change(w.agent.wallet.address(), agent_before, &w.contracts.usdc).await;

    // Charge tab
    let call_count: u32 = 1;
    let charge_sig = sign_tab_charge(
        &w.provider.signing_key,
        &w.contracts.tab,
        &tab.id,
        charge_units,
        call_count,
        w.contracts.chain_id,
    );
    let charge = w
        .provider
        .wallet
        .charge_tab(&tab.id, charge_amount, charge_amount, call_count, &charge_sig)
        .await
        .expect("charge_tab");
    assert_eq!(charge.tab_id, tab.id, "charge tab_id mismatch");
    eprintln!("[ACCEPTANCE] tab | charge | amount={}", charge.amount);

    // Close tab
    let close_sig = sign_tab_charge(
        &w.provider.signing_key,
        &w.contracts.tab,
        &tab.id,
        charge_units,
        call_count,
        w.contracts.chain_id,
    );
    let closed = w
        .agent
        .wallet
        .close_tab(&tab.id, charge_amount, &close_sig)
        .await
        .expect("close_tab");
    assert!(
        closed.tx_hash.starts_with("0x"),
        "close_tab tx_hash missing"
    );
    log_tx("tab", "close", &closed.tx_hash);

    let provider_after =
        wait_for_balance_change(w.provider.wallet.address(), provider_before, &w.contracts.usdc)
            .await;
    let agent_after = get_usdc_balance(w.agent.wallet.address(), &w.contracts.usdc).await;

    assert_balance_change("agent", agent_before, agent_after, -charge_amount);
    assert_balance_change(
        "provider",
        provider_before,
        provider_after,
        charge_amount * 0.99,
    );
}

// 4. Stream lifecycle
#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_04_stream() {
    let w = get_wallets().await;
    let rate = 0.1; // $0.10/s
    let max_total = 2.0;

    let agent_before = get_usdc_balance(w.agent.wallet.address(), &w.contracts.usdc).await;
    let provider_before = get_usdc_balance(w.provider.wallet.address(), &w.contracts.usdc).await;

    let permit = w
        .agent
        .wallet
        .sign_permit("stream", max_total + 1.0)
        .await
        .expect("sign_permit stream");
    let stream = w
        .agent
        .wallet
        .create_stream_with_permit(
            w.provider.wallet.address(),
            Decimal::from_str("0.1").unwrap(),
            Decimal::from_str("2.0").unwrap(),
            Some(permit),
        )
        .await
        .expect("create_stream_with_permit");

    assert!(!stream.id.is_empty(), "stream ID should not be empty");
    log_tx(
        "stream",
        &format!("open rate={rate}/s max={max_total}"),
        &stream.tx_hash,
    );

    wait_for_balance_change(w.agent.wallet.address(), agent_before, &w.contracts.usdc).await;
    eprintln!("[ACCEPTANCE] stream | waiting 5s for accrual...");
    tokio::time::sleep(std::time::Duration::from_secs(5)).await;

    let closed = w
        .agent
        .wallet
        .close_stream(&stream.id)
        .await
        .expect("close_stream");
    log_tx("stream", "close", &closed.tx_hash);

    let provider_after =
        wait_for_balance_change(w.provider.wallet.address(), provider_before, &w.contracts.usdc)
            .await;
    let agent_after = get_usdc_balance(w.agent.wallet.address(), &w.contracts.usdc).await;

    let agent_loss = agent_before - agent_after;
    assert!(
        agent_loss > 0.05,
        "agent should lose money, loss={agent_loss}"
    );
    assert!(agent_loss <= max_total + 0.01);

    let provider_gain = provider_after - provider_before;
    assert!(
        provider_gain > 0.04,
        "provider should gain, gain={provider_gain}"
    );
}

// 5. Bounty lifecycle (with retry for Ponder indexer lag)
#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_05_bounty() {
    let w = get_wallets().await;
    let amount = 2.0;
    let deadline_ts = now_unix() + 3600;

    let agent_before = get_usdc_balance(w.agent.wallet.address(), &w.contracts.usdc).await;
    let provider_before = get_usdc_balance(w.provider.wallet.address(), &w.contracts.usdc).await;

    let permit = w
        .agent
        .wallet
        .sign_permit("bounty", amount + 1.0)
        .await
        .expect("sign_permit bounty");
    let bounty = w
        .agent
        .wallet
        .create_bounty_with_permit(
            Decimal::from_str("2.0").unwrap(),
            "acceptance-bounty",
            deadline_ts,
            permit,
        )
        .await
        .expect("create_bounty_with_permit");

    assert!(!bounty.id.is_empty(), "bounty ID should not be empty");
    log_tx("bounty", &format!("post {amount} USDC"), &bounty.tx_hash);

    wait_for_balance_change(w.agent.wallet.address(), agent_before, &w.contracts.usdc).await;

    // Submit evidence
    let evidence_hash = format!("0x{}", hex::encode(keccak256(b"test evidence")));
    let submission = w
        .provider
        .wallet
        .submit_bounty(&bounty.id, &evidence_hash)
        .await
        .expect("submit_bounty");
    eprintln!(
        "[ACCEPTANCE] bounty | submit | id={} sub_id={}",
        bounty.id, submission.id
    );

    // Retry award up to 15 times with 3s sleep (Ponder indexer lag)
    let mut awarded = None;
    for attempt in 0..15 {
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        match w
            .agent
            .wallet
            .award_bounty(&bounty.id, submission.id)
            .await
        {
            Ok(b) => {
                awarded = Some(b);
                break;
            }
            Err(e) => {
                if attempt < 14 {
                    eprintln!("[ACCEPTANCE] bounty award retry {}: {}", attempt + 1, e);
                } else {
                    panic!("bounty award failed after 15 retries: {}", e);
                }
            }
        }
    }
    let awarded = awarded.expect("bounty should be awarded");
    log_tx("bounty", "award", &awarded.tx_hash);

    let provider_after =
        wait_for_balance_change(w.provider.wallet.address(), provider_before, &w.contracts.usdc)
            .await;
    let agent_after = get_usdc_balance(w.agent.wallet.address(), &w.contracts.usdc).await;

    assert_balance_change("agent", agent_before, agent_after, -amount);
    assert_balance_change("provider", provider_before, provider_after, amount * 0.99);
}

// 6. Deposit lifecycle (place + return)
#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_06_deposit() {
    let w = get_wallets().await;
    let amount = 2.0;

    let agent_before = get_usdc_balance(w.agent.wallet.address(), &w.contracts.usdc).await;

    let permit = w
        .agent
        .wallet
        .sign_permit("deposit", amount + 1.0)
        .await
        .expect("sign_permit deposit");
    let deposit = w
        .agent
        .wallet
        .lock_deposit_with_permit(
            w.provider.wallet.address(),
            Decimal::from_str("2.0").unwrap(),
            3600,
            permit,
        )
        .await
        .expect("lock_deposit_with_permit");

    assert!(!deposit.id.is_empty(), "deposit ID should not be empty");
    log_tx("deposit", &format!("place {amount} USDC"), &deposit.tx_hash);

    let agent_mid =
        wait_for_balance_change(w.agent.wallet.address(), agent_before, &w.contracts.usdc).await;
    assert_balance_change("agent locked", agent_before, agent_mid, -amount);

    let returned: serde_json::Value = w
        .provider
        .wallet
        .return_deposit(&deposit.id)
        .await
        .expect("return_deposit");
    if let Some(tx) = returned.get("tx_hash").and_then(|v| v.as_str()) {
        log_tx("deposit", "return", tx);
    }
    eprintln!("[ACCEPTANCE] deposit | returned");

    let agent_after =
        wait_for_balance_change(w.agent.wallet.address(), agent_mid, &w.contracts.usdc).await;
    assert_balance_change("agent refund", agent_before, agent_after, 0.0);
}

// 7. x402 prepare (no local HTTP server)
#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_07_x402_prepare() {
    let w = get_wallets().await;

    let contracts = w.agent.wallet.get_contracts().await.expect("get_contracts");

    let payment_required = serde_json::json!({
        "scheme": "exact",
        "network": "eip155:84532",
        "amount": "100000",
        "asset": contracts.usdc,
        "payTo": contracts.router,
        "maxTimeoutSeconds": 60,
    });
    use base64::Engine;
    let encoded = base64::engine::general_purpose::STANDARD
        .encode(serde_json::to_string(&payment_required).unwrap());

    let url = format!("{}/api/v1/x402/prepare", api_url());
    let body = serde_json::json!({
        "payment_required": encoded,
        "payer": w.agent.wallet.address(),
    });

    let data = authenticated_post(
        &url,
        "/api/v1/x402/prepare",
        &body,
        &w.agent.signing_key,
        w.agent.wallet.address(),
        w.contracts.chain_id,
        &w.contracts.router,
    )
    .await;

    let hash = data["hash"].as_str().expect("x402/prepare missing hash");
    assert!(hash.starts_with("0x"), "hash should start with 0x");
    assert_eq!(hash.len(), 66, "hash should be 66 chars (0x + 64 hex)");
    assert!(data["from"].is_string(), "missing from field");
    assert!(data["to"].is_string(), "missing to field");
    assert!(data["value"].is_string() || data["value"].is_number(), "missing value field");

    eprintln!(
        "[ACCEPTANCE] x402 | prepare | hash={}... | from={}...",
        &hash[..18],
        &data["from"].as_str().unwrap_or("?")[..10]
    );
}

// 8. AP2 Discovery (agent card)
#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_08_ap2_discovery() {
    let card = AgentCard::discover(&api_url())
        .await
        .expect("agent card discovery");

    assert!(!card.name.is_empty(), "agent card should have a name");
    assert!(!card.url.is_empty(), "agent card should have a URL");
    assert!(
        !card.skills.is_empty(),
        "agent card should have skills"
    );
    // x402 field is always present (struct field, not Option)
    assert!(
        !card.x402.settle_endpoint.is_empty(),
        "agent card should have x402 settle_endpoint"
    );

    eprintln!(
        "[ACCEPTANCE] ap2-discovery | name={} | skills={} | x402=true",
        card.name,
        card.skills.len()
    );
}

// 9. AP2 Payment (A2A JSON-RPC)
#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_09_ap2_payment() {
    let w = get_wallets().await;
    let amount = 1.0;

    let agent_before = get_usdc_balance(w.agent.wallet.address(), &w.contracts.usdc).await;
    let provider_before = get_usdc_balance(w.provider.wallet.address(), &w.contracts.usdc).await;

    let card = AgentCard::discover(&api_url())
        .await
        .expect("agent card discovery");

    let permit = w.agent.wallet.sign_permit("direct", 2.0).await.expect("sign_permit direct");

    let signer = Arc::new(
        PrivateKeySigner::new(&w.agent.hex_key).expect("create signer"),
    );
    let a2a = A2AClient::from_card(&card, signer);

    let task = a2a
        .send(SendOptions {
            to: w.provider.wallet.address().to_string(),
            amount,
            memo: Some("acceptance-ap2".to_string()),
            mandate: None,
            permit: Some(permit),
        })
        .await
        .expect("A2A send");

    assert_eq!(
        task.status.state, "completed",
        "A2A task should complete, got state={}, message={:?}",
        task.status.state, task.status.message
    );

    let tx_hash = get_task_tx_hash(&task).expect("A2A task should have txHash");
    assert!(tx_hash.starts_with("0x"), "bad tx hash: {tx_hash}");
    log_tx("ap2-payment", &format!("{amount} USDC via A2A"), &tx_hash);

    let agent_after =
        wait_for_balance_change(w.agent.wallet.address(), agent_before, &w.contracts.usdc).await;
    let provider_after =
        get_usdc_balance(w.provider.wallet.address(), &w.contracts.usdc).await;

    assert_balance_change("agent", agent_before, agent_after, -amount);
    assert_balance_change("provider", provider_before, provider_after, amount * 0.99);
}
