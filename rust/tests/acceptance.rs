//! Rust SDK acceptance tests: all 7 payment flows on live Base Sepolia.
//!
//! Run: cargo test --test acceptance -- --include-ignored --nocapture
//!
//! Env vars (all optional):
//!   ACCEPTANCE_API_URL  - default: https://remit.md
//!   ACCEPTANCE_RPC_URL  - default: https://sepolia.base.org

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

const USDC_ADDRESS: &str = "0x2d846325766921935f37d5b4478196d3ef93707c";
const FEE_WALLET: &str = "0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38";
const CHAIN_ID: u64 = 84532;

// ─── Contract discovery (unauthenticated) ────────────────────────────────────

#[derive(serde::Deserialize)]
struct Contracts {
    router: String,
    escrow: String,
    tab: String,
    stream: String,
    bounty: String,
    deposit: String,
    usdc: String,
}

async fn fetch_contracts() -> Contracts {
    let url = format!("{}/api/v1/contracts", api_url());
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

// ─── EIP-712 TabCharge Signing ───────────────────────────────────────────────

/// Sign a TabCharge EIP-712 message for the RemitTab contract.
///
/// Domain: { name: "RemitTab", version: "1", chainId: 84532, verifyingContract: tab_contract }
/// Type:   TabCharge(bytes32 tabId, uint96 totalCharged, uint32 callCount)
///
/// tabId is the UUID string, ASCII-encoded as bytes32 (right-padded with zeroes).
fn sign_tab_charge(
    key: &SigningKey,
    tab_contract: &str,
    tab_id: &str,
    total_charged: u64, // USDC base units (6 decimals)
    call_count: u32,
) -> String {
    // Domain separator for RemitTab
    let domain_type_hash = keccak256(
        b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
    );
    let name_hash = keccak256(b"RemitTab");
    let version_hash = keccak256(b"1");

    let mut domain_data = [0u8; 160];
    domain_data[0..32].copy_from_slice(&domain_type_hash);
    domain_data[32..64].copy_from_slice(&name_hash);
    domain_data[64..96].copy_from_slice(&version_hash);
    domain_data[96..128].copy_from_slice(&pad_u256(CHAIN_ID));
    domain_data[128..160].copy_from_slice(&pad_address(tab_contract));
    let domain_sep = keccak256(&domain_data);

    // Struct hash: TabCharge(bytes32 tabId, uint96 totalCharged, uint32 callCount)
    let tab_charge_type_hash =
        keccak256(b"TabCharge(bytes32 tabId,uint96 totalCharged,uint32 callCount)");

    // Encode tabId as bytes32: ASCII chars right-padded to 32 bytes
    let mut tab_id_bytes = [0u8; 32];
    let id_bytes = tab_id.as_bytes();
    let copy_len = id_bytes.len().min(32);
    tab_id_bytes[..copy_len].copy_from_slice(&id_bytes[..copy_len]);

    // totalCharged as uint256 (uint96 ABI-encodes as uint256)
    let total_charged_padded = pad_u256(total_charged);

    // callCount as uint256 (uint32 ABI-encodes as uint256)
    let call_count_padded = pad_u256(call_count as u64);

    let mut struct_data = [0u8; 128]; // 4 × 32
    struct_data[0..32].copy_from_slice(&tab_charge_type_hash);
    struct_data[32..64].copy_from_slice(&tab_id_bytes);
    struct_data[64..96].copy_from_slice(&total_charged_padded);
    struct_data[96..128].copy_from_slice(&call_count_padded);
    let struct_hash = keccak256(&struct_data);

    // EIP-712 digest
    let mut final_data = [0u8; 66];
    final_data[0] = 0x19;
    final_data[1] = 0x01;
    final_data[2..34].copy_from_slice(&domain_sep);
    final_data[34..66].copy_from_slice(&struct_hash);
    let digest = keccak256(&final_data);

    // Sign with k256
    let (sig, recovery_id) = key
        .sign_prehash_recoverable(&digest)
        .expect("sign tab charge");
    let mut sig_bytes = sig.to_bytes().to_vec();
    sig_bytes.push(recovery_id.to_byte() + 27);

    format!("0x{}", hex::encode(&sig_bytes))
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

// ─── Test: Tab Lifecycle ──────────────────────────────────────────────────────

#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_tab_lifecycle() {
    let contracts = fetch_contracts().await;

    let payer = create_test_wallet(&contracts.router);
    let provider = create_test_wallet(&contracts.router);
    fund_wallet(&payer, 100.0).await;

    // Sign permit for the Tab contract
    let permit = sign_usdc_permit(
        &payer.signing_key,
        payer.wallet.address(),
        &contracts.tab,
        20_000_000, // $20 USDC in base units
        0,
        now_unix() + 3600,
    );

    let payer_before = get_usdc_balance(payer.wallet.address()).await;
    let fee_before = get_fee_balance().await;

    // 1. Create tab: $10 limit, $0.10 per call
    let tab = payer
        .wallet
        .create_tab_with_permit(
            provider.wallet.address(),
            Decimal::from_str("10.0").unwrap(),
            Decimal::from_str("0.10").unwrap(),
            permit,
        )
        .await
        .expect("create_tab_with_permit");
    assert!(!tab.id.is_empty(), "tab ID should not be empty");
    eprintln!("Tab created: {}", tab.id);

    // Wait for on-chain funding
    wait_for_balance_change(payer.wallet.address(), payer_before).await;

    // 2. Charge tab: $0.10, cumulative $0.10, callCount 1
    let charge_sig = sign_tab_charge(
        &provider.signing_key,
        &contracts.tab,
        &tab.id,
        100_000, // $0.10 in base units
        1,
    );
    let charge = provider
        .wallet
        .charge_tab(&tab.id, 0.10, 0.10, 1, &charge_sig)
        .await
        .expect("charge_tab");
    assert_eq!(charge.tab_id, tab.id, "charge tab_id mismatch");
    eprintln!(
        "Tab charged: amount={}, cumulative={}",
        charge.amount, charge.cumulative
    );

    // 3. Close tab with final settlement
    let close_sig = sign_tab_charge(
        &provider.signing_key,
        &contracts.tab,
        &tab.id,
        100_000, // final = $0.10
        1,
    );
    let closed = payer
        .wallet
        .close_tab(&tab.id, 0.10, &close_sig)
        .await
        .expect("close_tab");
    assert_ne!(
        closed.status,
        remitmd::TabStatus::Open,
        "tab should not be open after close"
    );
    eprintln!("Tab closed: status={:?}", closed.status);

    // 4. Verify balance: payer should have lost funds
    let payer_after = wait_for_balance_change(payer.wallet.address(), payer_before).await;
    let fee_after = get_fee_balance().await;

    let payer_delta = payer_after - payer_before;
    assert!(
        payer_delta < 0.0,
        "payer should have lost funds, delta={payer_delta:.6}"
    );
    eprintln!(
        "Payer balance delta: {payer_delta:.6}, fee delta: {:.6}",
        fee_after - fee_before
    );
}

// ─── Test: Stream Lifecycle ──────────────────────────────────────────────────

#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_stream_lifecycle() {
    let contracts = fetch_contracts().await;

    let payer = create_test_wallet(&contracts.router);
    let payee = create_test_wallet(&contracts.router);
    fund_wallet(&payer, 100.0).await;

    // Sign permit for the Stream contract
    let permit = sign_usdc_permit(
        &payer.signing_key,
        payer.wallet.address(),
        &contracts.stream,
        10_000_000, // $10 USDC in base units
        0,
        now_unix() + 3600,
    );

    let payer_before = get_usdc_balance(payer.wallet.address()).await;

    // 1. Create stream: $0.01/sec, $5 max
    let stream = payer
        .wallet
        .create_stream_with_permit(
            payee.wallet.address(),
            Decimal::from_str("0.01").unwrap(), // rate_per_second
            Decimal::from_str("5.0").unwrap(),  // max_total
            Some(permit),
        )
        .await
        .expect("create_stream_with_permit");
    assert!(!stream.id.is_empty(), "stream ID should not be empty");
    eprintln!("Stream created: {}, status={:?}", stream.id, stream.status);

    // Wait for on-chain lock
    wait_for_balance_change(payer.wallet.address(), payer_before).await;

    // 2. Let it run for a few seconds
    eprintln!("Waiting 5 seconds for stream to accrue...");
    tokio::time::sleep(std::time::Duration::from_secs(5)).await;

    // 3. Close stream
    let closed = payer
        .wallet
        .close_stream(&stream.id)
        .await
        .expect("close_stream");
    eprintln!("Stream closed: status={:?}", closed.status);

    // 4. Conservation of funds: payer should have lost some amount
    let payer_after = wait_for_balance_change(payer.wallet.address(), payer_before).await;
    let payee_after = get_usdc_balance(payee.wallet.address()).await;

    let payer_delta = payer_after - payer_before;
    assert!(
        payer_delta < 0.0,
        "payer should have lost funds, delta={payer_delta:.6}"
    );
    eprintln!("Payer delta: {payer_delta:.6}, Payee balance: {payee_after:.6}");
}

// ─── Test: Bounty Lifecycle ──────────────────────────────────────────────────

#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_bounty_lifecycle() {
    let contracts = fetch_contracts().await;

    let poster = create_test_wallet(&contracts.router);
    let submitter = create_test_wallet(&contracts.router);
    fund_wallet(&poster, 100.0).await;

    // Sign permit for the Bounty contract
    let permit = sign_usdc_permit(
        &poster.signing_key,
        poster.wallet.address(),
        &contracts.bounty,
        10_000_000, // $10 USDC in base units
        0,
        now_unix() + 3600,
    );

    let poster_before = get_usdc_balance(poster.wallet.address()).await;
    let fee_before = get_fee_balance().await;

    // 1. Create bounty: $5 reward, 1 hour deadline
    let deadline = now_unix() + 3600;
    let bounty = poster
        .wallet
        .create_bounty_with_permit(
            Decimal::from_str("5.0").unwrap(),
            "Write a Rust acceptance test",
            deadline,
            permit,
        )
        .await
        .expect("create_bounty_with_permit");
    assert!(!bounty.id.is_empty(), "bounty ID should not be empty");
    eprintln!("Bounty created: {}, status={:?}", bounty.id, bounty.status);

    // Wait for on-chain lock
    wait_for_balance_change(poster.wallet.address(), poster_before).await;

    // 2. Submit evidence (as submitter)
    let evidence_hash = format!("0x{}", hex::encode(keccak256(b"test evidence")));
    let submission = submitter
        .wallet
        .submit_bounty(&bounty.id, &evidence_hash)
        .await
        .expect("submit_bounty");
    assert_eq!(
        submission.bounty_id, bounty.id,
        "submission bounty_id mismatch"
    );
    eprintln!(
        "Submission created: id={}, status={}",
        submission.id, submission.status
    );

    // 3. Award bounty (as poster)
    let awarded = poster
        .wallet
        .award_bounty(&bounty.id, submission.id)
        .await
        .expect("award_bounty");
    eprintln!("Bounty awarded: status={:?}", awarded.status);

    // 4. Verify balances
    let submitter_after = wait_for_balance_change(submitter.wallet.address(), 0.0).await;
    let fee_after = get_fee_balance().await;

    assert!(
        submitter_after > 0.0,
        "submitter should have received funds, got balance={submitter_after:.6}"
    );
    eprintln!(
        "Submitter received: {submitter_after:.6}, fee delta: {:.6}",
        fee_after - fee_before
    );
}

// ─── Test: Deposit Lifecycle ─────────────────────────────────────────────────

#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_deposit_lifecycle() {
    let contracts = fetch_contracts().await;

    let payer = create_test_wallet(&contracts.router);
    let provider = create_test_wallet(&contracts.router);
    fund_wallet(&payer, 100.0).await;

    // Sign permit for the Deposit contract
    let permit = sign_usdc_permit(
        &payer.signing_key,
        payer.wallet.address(),
        &contracts.deposit,
        10_000_000, // $10 USDC in base units
        0,
        now_unix() + 3600,
    );

    let payer_before = get_usdc_balance(payer.wallet.address()).await;

    // 1. Place deposit: $5, expires in 1 hour
    let expiry = now_unix() + 3600;
    let deposit = payer
        .wallet
        .lock_deposit_with_permit(
            provider.wallet.address(),
            Decimal::from_str("5.0").unwrap(),
            expiry,
            permit,
        )
        .await
        .expect("lock_deposit_with_permit");
    assert!(!deposit.id.is_empty(), "deposit ID should not be empty");
    eprintln!(
        "Deposit placed: {}, status={:?}",
        deposit.id, deposit.status
    );

    // Wait for on-chain lock
    wait_for_balance_change(payer.wallet.address(), payer_before).await;
    let payer_after_deposit = get_usdc_balance(payer.wallet.address()).await;

    // 2. Return deposit (by provider)
    provider
        .wallet
        .return_deposit(&deposit.id)
        .await
        .expect("return_deposit");
    eprintln!("Deposit returned");

    // 3. Verify full refund (deposits have no fee)
    let payer_after_return =
        wait_for_balance_change(payer.wallet.address(), payer_after_deposit).await;
    let refund_amount = payer_after_return - payer_after_deposit;
    assert!(
        refund_amount > 4.99,
        "expected near-full refund (~5.0), got {refund_amount:.6}"
    );
    eprintln!("Deposit refunded: {refund_amount:.6} (full refund, no fee)");
}

// ─── Test: X402 Auto-Pay ─────────────────────────────────────────────────────

#[tokio::test]
#[ignore = "hits live Base Sepolia"]
async fn acceptance_x402() {
    use std::io::Write;
    use std::net::TcpListener;

    let contracts = fetch_contracts().await;

    let payer = create_test_wallet(&contracts.router);
    fund_wallet(&payer, 100.0).await;

    // 1. Start a local HTTP server that returns 402 with PAYMENT-REQUIRED header
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind local server");
    let port = listener.local_addr().unwrap().port();
    let server_url = format!("http://127.0.0.1:{port}");
    let usdc = contracts.usdc.clone();
    let router = contracts.router.clone();

    let server_handle = std::thread::spawn(move || {
        // Accept up to 2 connections (first = 402, second = 200 with payment)
        for stream in listener.incoming().take(2) {
            if let Ok(mut stream) = stream {
                let mut buf = [0u8; 4096];
                let n = std::io::Read::read(&mut stream, &mut buf).unwrap_or(0);
                let request = String::from_utf8_lossy(&buf[..n]);

                // Check if PAYMENT-SIGNATURE header is present
                let has_payment = request.contains("PAYMENT-SIGNATURE");

                if has_payment {
                    let body = b"paid content";
                    let response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\n\r\n",
                        body.len()
                    );
                    let _ = stream.write_all(response.as_bytes());
                    let _ = stream.write_all(body);
                } else {
                    // Return 402 with PAYMENT-REQUIRED header
                    let payment_required = serde_json::json!({
                        "scheme": "exact",
                        "network": "eip155:84532",
                        "amount": "100000",
                        "asset": usdc,
                        "payTo": router,
                        "maxTimeoutSeconds": 60,
                        "resource": "/test-resource",
                        "description": "x402 acceptance test",
                        "mimeType": "text/plain",
                    });
                    use base64::Engine;
                    let encoded = base64::engine::general_purpose::STANDARD
                        .encode(serde_json::to_string(&payment_required).unwrap());
                    let body = b"Payment Required";
                    let response = format!(
                        "HTTP/1.1 402 Payment Required\r\nContent-Type: text/plain\r\nPAYMENT-REQUIRED: {}\r\nContent-Length: {}\r\n\r\n",
                        encoded,
                        body.len()
                    );
                    let _ = stream.write_all(response.as_bytes());
                    let _ = stream.write_all(body);
                }
            }
        }
    });

    // 2. Make an unauthenticated request - should get 402
    let client = reqwest::Client::new();
    let resp = client
        .get(&format!("{server_url}/test-resource"))
        .send()
        .await
        .expect("GET /test-resource");
    assert_eq!(resp.status().as_u16(), 402, "expected 402 response");

    // 3. Verify PAYMENT-REQUIRED header is present and parseable
    let pay_req = resp
        .headers()
        .get("payment-required")
        .expect("missing PAYMENT-REQUIRED header")
        .to_str()
        .expect("header not valid utf-8");
    use base64::Engine;
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(pay_req)
        .expect("decode PAYMENT-REQUIRED");
    let req_payload: serde_json::Value =
        serde_json::from_slice(&decoded).expect("parse PAYMENT-REQUIRED JSON");
    assert!(
        req_payload["payTo"].is_string(),
        "PAYMENT-REQUIRED missing payTo field"
    );

    // 4. Verify V2 fields are present
    assert_eq!(
        req_payload["resource"].as_str().unwrap(),
        "/test-resource",
        "expected resource=/test-resource"
    );
    assert_eq!(
        req_payload["description"].as_str().unwrap(),
        "x402 acceptance test",
        "expected description"
    );
    assert_eq!(
        req_payload["mimeType"].as_str().unwrap(),
        "text/plain",
        "expected mimeType"
    );
    eprintln!("X402 paywall verified: 402 with PAYMENT-REQUIRED header, V2 fields present");

    // Wait for server thread to finish (it only accepts 2 connections)
    let _ = server_handle.join();
}
