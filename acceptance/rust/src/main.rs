//! Rust SDK Acceptance — 9 flows against Base Sepolia.
//!
//! Flows: Direct, Escrow, Tab (2 charges), Stream, Bounty, Deposit,
//!        x402 Weather, AP2 Discovery, AP2 Payment.
//!
//! Usage:
//!     ACCEPTANCE_API_URL=https://testnet.remit.md cargo run

use remitmd::a2a::{get_task_tx_hash, A2AClient, AgentCard, SendOptions};
use remitmd::{PermitSignature, PrivateKeySigner, Wallet};
use rust_decimal::Decimal;
use sha3::{Digest, Keccak256};
use std::env;
use std::str::FromStr;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

// ─── Config ──────────────────────────────────────────────────────────────────

fn api_url() -> String {
    env::var("ACCEPTANCE_API_URL").unwrap_or_else(|_| "https://testnet.remit.md".to_string())
}

fn rpc_url() -> String {
    env::var("ACCEPTANCE_RPC_URL").unwrap_or_else(|_| "https://sepolia.base.org".to_string())
}

const CHAIN_ID: u64 = 84532;
const USDC_ADDRESS: &str = "0x2d846325766921935f37d5b4478196d3ef93707c";
const FEE_WALLET: &str = "0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38";

// ─── Colors ──────────────────────────────────────────────────────────────────

const GREEN: &str = "\x1b[0;32m";
const RED: &str = "\x1b[0;31m";
const CYAN: &str = "\x1b[0;36m";
const BOLD: &str = "\x1b[1m";
const RESET: &str = "\x1b[0m";

// ─── Results ─────────────────────────────────────────────────────────────────

struct Results {
    entries: Vec<(String, String)>,
}

impl Results {
    fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }

    fn pass(&mut self, flow: &str, msg: &str) {
        let extra = if msg.is_empty() {
            String::new()
        } else {
            format!(" — {msg}")
        };
        println!("{GREEN}[PASS]{RESET} {flow}{extra}");
        self.entries.push((flow.to_string(), "PASS".to_string()));
    }

    fn fail(&mut self, flow: &str, msg: &str) {
        println!("{RED}[FAIL]{RESET} {flow} — {msg}");
        self.entries.push((flow.to_string(), "FAIL".to_string()));
    }

    fn passed(&self) -> usize {
        self.entries.iter().filter(|(_, s)| s == "PASS").count()
    }

    fn failed(&self) -> usize {
        self.entries.iter().filter(|(_, s)| s == "FAIL").count()
    }
}

fn log_info(msg: &str) {
    println!("{CYAN}[INFO]{RESET} {msg}");
}

fn log_tx(flow: &str, step: &str, tx_hash: &str) {
    println!("  [TX] {flow} | {step} | https://sepolia.basescan.org/tx/{tx_hash}");
}

// ─── Contract discovery ──────────────────────────────────────────────────────

#[derive(serde::Deserialize, Clone)]
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
    signing_key: k256::ecdsa::SigningKey,
    hex_key: String,
}

fn create_test_wallet(router: &str) -> TestWallet {
    let signing_key = k256::ecdsa::SigningKey::random(&mut rand::rngs::OsRng);
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
        hex_key,
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

async fn fund_wallet(w: &TestWallet, amount: f64) {
    w.wallet.mint(amount).await.expect("mint");
    wait_for_balance_change(w.wallet.address(), 0.0).await;
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

// ─── EIP-712 / Crypto helpers ────────────────────────────────────────────────

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
    key: &k256::ecdsa::SigningKey,
    owner: &str,
    spender: &str,
    value: u64,
    nonce: u64,
    deadline: u64,
) -> PermitSignature {
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

    let permit_type_hash = keccak256(
        b"Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)",
    );

    let mut struct_data = [0u8; 192];
    struct_data[0..32].copy_from_slice(&permit_type_hash);
    struct_data[32..64].copy_from_slice(&pad_address(owner));
    struct_data[64..96].copy_from_slice(&pad_address(spender));
    struct_data[96..128].copy_from_slice(&pad_u256(value));
    struct_data[128..160].copy_from_slice(&pad_u256(nonce));
    struct_data[160..192].copy_from_slice(&pad_u256(deadline));
    let struct_hash = keccak256(&struct_data);

    let mut final_data = [0u8; 66];
    final_data[0] = 0x19;
    final_data[1] = 0x01;
    final_data[2..34].copy_from_slice(&domain_sep);
    final_data[34..66].copy_from_slice(&struct_hash);
    let digest = keccak256(&final_data);

    use k256::ecdsa::signature::hazmat::PrehashSigner;
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

// ─── EIP-712 TabCharge Signing ───────────────────────────────────────────────

fn sign_tab_charge(
    key: &k256::ecdsa::SigningKey,
    tab_contract: &str,
    tab_id: &str,
    total_charged: u64,
    call_count: u32,
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
    domain_data[96..128].copy_from_slice(&pad_u256(CHAIN_ID));
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

    use k256::ecdsa::signature::hazmat::PrehashSigner;
    let (sig, recovery_id) = key
        .sign_prehash_recoverable(&digest)
        .expect("sign tab charge");
    let mut sig_bytes = sig.to_bytes().to_vec();
    sig_bytes.push(recovery_id.to_byte() + 27);

    format!("0x{}", hex::encode(&sig_bytes))
}

// ─── EIP-3009 TransferWithAuthorization signing ──────────────────────────────

fn sign_eip3009(
    key: &k256::ecdsa::SigningKey,
    from: &str,
    to: &str,
    value: u64,
    valid_before: u64,
    nonce_bytes: &[u8; 32],
    chain_id: u64,
    usdc_addr: &str,
) -> (String, String) {
    // Domain separator
    let domain_type_hash = keccak256(
        b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
    );
    let name_hash = keccak256(b"USD Coin");
    let version_hash = keccak256(b"2");

    let usdc_hex = usdc_addr.trim_start_matches("0x");
    let usdc_bytes = hex::decode(usdc_hex).expect("decode USDC address");
    let mut usdc_padded = [0u8; 32];
    usdc_padded[12..].copy_from_slice(&usdc_bytes);

    let mut domain_data = [0u8; 160];
    domain_data[0..32].copy_from_slice(&domain_type_hash);
    domain_data[32..64].copy_from_slice(&name_hash);
    domain_data[64..96].copy_from_slice(&version_hash);
    domain_data[96..128].copy_from_slice(&pad_u256(chain_id));
    domain_data[128..160].copy_from_slice(&usdc_padded);
    let domain_sep = keccak256(&domain_data);

    // Struct hash
    let type_hash = keccak256(
        b"TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)",
    );

    let mut struct_data = Vec::with_capacity(224);
    struct_data.extend_from_slice(&type_hash);
    struct_data.extend_from_slice(&pad_address(from));
    struct_data.extend_from_slice(&pad_address(to));
    struct_data.extend_from_slice(&pad_u256(value));
    struct_data.extend_from_slice(&pad_u256(0)); // validAfter = 0
    struct_data.extend_from_slice(&pad_u256(valid_before));
    struct_data.extend_from_slice(nonce_bytes);
    let struct_hash = keccak256(&struct_data);

    // EIP-712 digest
    let mut final_data = [0u8; 66];
    final_data[0] = 0x19;
    final_data[1] = 0x01;
    final_data[2..34].copy_from_slice(&domain_sep);
    final_data[34..66].copy_from_slice(&struct_hash);
    let digest = keccak256(&final_data);

    use k256::ecdsa::signature::hazmat::PrehashSigner;
    let (sig, recovery_id) = key
        .sign_prehash_recoverable(&digest)
        .expect("sign eip3009");
    let mut sig_bytes = sig.to_bytes().to_vec();
    sig_bytes.push(recovery_id.to_byte() + 27);

    let nonce_hex = format!("0x{}", hex::encode(nonce_bytes));
    let signature = format!("0x{}", hex::encode(&sig_bytes));
    (signature, nonce_hex)
}

// ─── EIP-712 API Auth ────────────────────────────────────────────────────────

fn sign_api_auth(
    key: &k256::ecdsa::SigningKey,
    method: &str,
    path: &str,
    router_address: &str,
) -> (String, String, String, String) {
    // Domain: remit.md / 0.1
    let domain_type_hash = keccak256(
        b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
    );
    let name_hash = keccak256(b"remit.md");
    let version_hash = keccak256(b"0.1");

    let mut domain_data = [0u8; 160];
    domain_data[0..32].copy_from_slice(&domain_type_hash);
    domain_data[32..64].copy_from_slice(&name_hash);
    domain_data[64..96].copy_from_slice(&version_hash);
    domain_data[96..128].copy_from_slice(&pad_u256(CHAIN_ID));
    domain_data[128..160].copy_from_slice(&pad_address(router_address));
    let domain_sep = keccak256(&domain_data);

    // APIRequest struct — string fields are keccak256-hashed in EIP-712
    let auth_type_hash = keccak256(
        b"APIRequest(string method,string path,uint256 timestamp,bytes32 nonce)",
    );

    let timestamp = now_unix();
    let mut nonce_bytes = [0u8; 32];
    getrandom::getrandom(&mut nonce_bytes).expect("generate auth nonce");

    let method_hash = keccak256(method.as_bytes());
    let path_hash = keccak256(path.as_bytes());

    let mut struct_data = [0u8; 160];
    struct_data[0..32].copy_from_slice(&auth_type_hash);
    struct_data[32..64].copy_from_slice(&method_hash);
    struct_data[64..96].copy_from_slice(&path_hash);
    struct_data[96..128].copy_from_slice(&pad_u256(timestamp));
    struct_data[128..160].copy_from_slice(&nonce_bytes);
    let struct_hash = keccak256(&struct_data);

    let mut final_data = [0u8; 66];
    final_data[0] = 0x19;
    final_data[1] = 0x01;
    final_data[2..34].copy_from_slice(&domain_sep);
    final_data[34..66].copy_from_slice(&struct_hash);
    let digest = keccak256(&final_data);

    use k256::ecdsa::signature::hazmat::PrehashSigner;
    let (sig, recovery_id) = key.sign_prehash_recoverable(&digest).expect("sign api auth");
    let mut sig_bytes = sig.to_bytes().to_vec();
    sig_bytes.push(recovery_id.to_byte() + 27);

    let verifying_key = key.verifying_key();
    let pubkey_bytes = verifying_key.to_encoded_point(false);
    let addr_hash = keccak256(&pubkey_bytes.as_bytes()[1..]);
    let agent_addr = format!("0x{}", hex::encode(&addr_hash[12..]));

    (
        format!("0x{}", hex::encode(&sig_bytes)),
        agent_addr,
        timestamp.to_string(),
        format!("0x{}", hex::encode(nonce_bytes)),
    )
}

// ─── Flow 1: Direct Payment ─────────────────────────────────────────────────

async fn flow_direct(
    agent: &TestWallet,
    provider: &TestWallet,
    contracts: &Contracts,
    results: &mut Results,
    permit_nonce: &mut u64,
) {
    let flow = "1. Direct Payment";
    let permit = sign_usdc_permit(
        &agent.signing_key,
        agent.wallet.address(),
        &contracts.router,
        2_000_000,
        *permit_nonce,
        now_unix() + 3600,
    );
    *permit_nonce += 1;

    let tx = agent
        .wallet
        .pay_full(
            provider.wallet.address(),
            Decimal::from_str("1.0").unwrap(),
            "acceptance-direct",
            Some(permit),
        )
        .await
        .expect("pay_full");

    assert!(
        tx.tx_hash.starts_with("0x"),
        "expected tx hash starting with 0x"
    );
    log_tx(flow, "pay", &tx.tx_hash);
    results.pass(flow, &format!("tx={}", &tx.tx_hash[..18]));
}

// ─── Flow 2: Escrow ─────────────────────────────────────────────────────────

async fn flow_escrow(
    agent: &TestWallet,
    provider: &TestWallet,
    contracts: &Contracts,
    results: &mut Results,
    permit_nonce: &mut u64,
) {
    let flow = "2. Escrow";
    let permit = sign_usdc_permit(
        &agent.signing_key,
        agent.wallet.address(),
        &contracts.escrow,
        6_000_000,
        *permit_nonce,
        now_unix() + 3600,
    );
    *permit_nonce += 1;

    let agent_before = get_usdc_balance(agent.wallet.address()).await;

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
    if !escrow.tx_hash.is_empty() {
        log_tx(flow, "fund", &escrow.tx_hash);
    }

    wait_for_balance_change(agent.wallet.address(), agent_before).await;
    tokio::time::sleep(std::time::Duration::from_secs(3)).await;

    let claim = provider
        .wallet
        .claim_start(&escrow.id)
        .await
        .expect("claim_start");
    if !claim.tx_hash.is_empty() {
        log_tx(flow, "claimStart", &claim.tx_hash);
    }
    tokio::time::sleep(std::time::Duration::from_secs(3)).await;

    let released = agent
        .wallet
        .release_escrow(&escrow.id, None)
        .await
        .expect("release_escrow");
    if !released.tx_hash.is_empty() {
        log_tx(flow, "release", &released.tx_hash);
    }
    results.pass(flow, &format!("escrow_id={}", escrow.id));
}

// ─── Flow 3: Metered Tab (2 charges) ────────────────────────────────────────

async fn flow_tab(
    agent: &TestWallet,
    provider: &TestWallet,
    contracts: &Contracts,
    results: &mut Results,
    permit_nonce: &mut u64,
) {
    let flow = "3. Metered Tab";
    let permit = sign_usdc_permit(
        &agent.signing_key,
        agent.wallet.address(),
        &contracts.tab,
        11_000_000,
        *permit_nonce,
        now_unix() + 3600,
    );
    *permit_nonce += 1;

    let agent_before = get_usdc_balance(agent.wallet.address()).await;

    let tab = agent
        .wallet
        .create_tab_with_permit(
            provider.wallet.address(),
            Decimal::from_str("10.0").unwrap(),
            Decimal::from_str("0.10").unwrap(),
            permit,
        )
        .await
        .expect("create_tab_with_permit");
    assert!(!tab.id.is_empty(), "tab should have an id");
    if !tab.tx_hash.is_empty() {
        log_tx(flow, "open", &tab.tx_hash);
    }

    wait_for_balance_change(agent.wallet.address(), agent_before).await;

    // Charge 1: $2
    let sig1 = sign_tab_charge(
        &provider.signing_key,
        &contracts.tab,
        &tab.id,
        2_000_000,
        1,
    );
    let _charge1 = provider
        .wallet
        .charge_tab(&tab.id, 2.0, 2.0, 1, &sig1)
        .await
        .expect("charge_tab 1");

    // Charge 2: $1 more (cumulative $3)
    let sig2 = sign_tab_charge(
        &provider.signing_key,
        &contracts.tab,
        &tab.id,
        3_000_000,
        2,
    );
    let _charge2 = provider
        .wallet
        .charge_tab(&tab.id, 1.0, 3.0, 2, &sig2)
        .await
        .expect("charge_tab 2");

    // Close with final state ($3, 2 calls)
    let close_sig = sign_tab_charge(
        &provider.signing_key,
        &contracts.tab,
        &tab.id,
        3_000_000,
        2,
    );
    let closed = agent
        .wallet
        .close_tab(&tab.id, 3.0, &close_sig)
        .await
        .expect("close_tab");

    assert_ne!(
        closed.status,
        remitmd::TabStatus::Open,
        "tab should not be open after close"
    );
    results.pass(flow, &format!("tab_id={}, charged=$3, 2 charges", tab.id));
}

// ─── Flow 4: Stream ─────────────────────────────────────────────────────────

async fn flow_stream(
    agent: &TestWallet,
    provider: &TestWallet,
    contracts: &Contracts,
    results: &mut Results,
    permit_nonce: &mut u64,
) {
    let flow = "4. Stream";
    let permit = sign_usdc_permit(
        &agent.signing_key,
        agent.wallet.address(),
        &contracts.stream,
        6_000_000,
        *permit_nonce,
        now_unix() + 3600,
    );
    *permit_nonce += 1;

    let stream = agent
        .wallet
        .create_stream_with_permit(
            provider.wallet.address(),
            Decimal::from_str("0.01").unwrap(),
            Decimal::from_str("5.0").unwrap(),
            Some(permit),
        )
        .await
        .expect("create_stream_with_permit");
    assert!(!stream.id.is_empty(), "stream should have an id");
    if !stream.tx_hash.is_empty() {
        log_tx(flow, "open", &stream.tx_hash);
    }

    log_info("  Waiting 5 seconds for stream to accrue...");
    tokio::time::sleep(std::time::Duration::from_secs(5)).await;

    let closed = agent
        .wallet
        .close_stream(&stream.id)
        .await
        .expect("close_stream");
    if !closed.tx_hash.is_empty() {
        log_tx(flow, "close", &closed.tx_hash);
    }
    results.pass(flow, &format!("stream_id={}", stream.id));
}

// ─── Flow 5: Bounty ─────────────────────────────────────────────────────────

async fn flow_bounty(
    agent: &TestWallet,
    provider: &TestWallet,
    contracts: &Contracts,
    results: &mut Results,
    permit_nonce: &mut u64,
) {
    let flow = "5. Bounty";
    let permit = sign_usdc_permit(
        &agent.signing_key,
        agent.wallet.address(),
        &contracts.bounty,
        6_000_000,
        *permit_nonce,
        now_unix() + 3600,
    );
    *permit_nonce += 1;

    let agent_before = get_usdc_balance(agent.wallet.address()).await;
    let deadline = now_unix() + 3600;

    let bounty = agent
        .wallet
        .create_bounty_with_permit(
            Decimal::from_str("5.0").unwrap(),
            "acceptance-bounty-test",
            deadline,
            permit,
        )
        .await
        .expect("create_bounty_with_permit");
    assert!(!bounty.id.is_empty(), "bounty should have an id");
    if !bounty.tx_hash.is_empty() {
        log_tx(flow, "post", &bounty.tx_hash);
    }

    wait_for_balance_change(agent.wallet.address(), agent_before).await;

    let evidence_hash = format!("0x{}", hex::encode(keccak256(b"test evidence")));
    let submission = provider
        .wallet
        .submit_bounty(&bounty.id, &evidence_hash)
        .await
        .expect("submit_bounty");
    assert_eq!(
        submission.bounty_id, bounty.id,
        "submission bounty_id mismatch"
    );

    tokio::time::sleep(std::time::Duration::from_secs(5)).await;

    let awarded = agent
        .wallet
        .award_bounty(&bounty.id, submission.id)
        .await
        .expect("award_bounty");
    if !awarded.tx_hash.is_empty() {
        log_tx(flow, "award", &awarded.tx_hash);
    }
    results.pass(flow, &format!("bounty_id={}", bounty.id));
}

// ─── Flow 6: Deposit ────────────────────────────────────────────────────────

async fn flow_deposit(
    agent: &TestWallet,
    provider: &TestWallet,
    contracts: &Contracts,
    results: &mut Results,
    permit_nonce: &mut u64,
) {
    let flow = "6. Deposit";
    let permit = sign_usdc_permit(
        &agent.signing_key,
        agent.wallet.address(),
        &contracts.deposit,
        6_000_000,
        *permit_nonce,
        now_unix() + 3600,
    );
    *permit_nonce += 1;

    let agent_before = get_usdc_balance(agent.wallet.address()).await;
    let expiry = now_unix() + 3600;

    let deposit = agent
        .wallet
        .lock_deposit_with_permit(
            provider.wallet.address(),
            Decimal::from_str("5.0").unwrap(),
            expiry,
            permit,
        )
        .await
        .expect("lock_deposit_with_permit");
    assert!(!deposit.id.is_empty(), "deposit should have an id");
    if !deposit.tx_hash.is_empty() {
        log_tx(flow, "place", &deposit.tx_hash);
    }

    wait_for_balance_change(agent.wallet.address(), agent_before).await;

    provider
        .wallet
        .return_deposit(&deposit.id)
        .await
        .expect("return_deposit");
    results.pass(flow, &format!("deposit_id={}", deposit.id));
}

// ─── Flow 7: x402 Weather (manual 3-step) ───────────────────────────────────

async fn flow_x402_weather(agent: &TestWallet, results: &mut Results) {
    let flow = "7. x402 Weather";
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .unwrap();
    let api = api_url();
    let base = format!("{api}/api/v1");

    // Step 1: Hit the paywall
    let resp = client
        .get(&format!("{base}/x402/demo"))
        .send()
        .await
        .expect("GET /x402/demo");

    if resp.status().as_u16() != 402 {
        results.fail(flow, &format!("expected 402, got {}", resp.status()));
        return;
    }

    let scheme = resp
        .headers()
        .get("x-payment-scheme")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("exact")
        .to_string();
    let network = resp
        .headers()
        .get("x-payment-network")
        .and_then(|v| v.to_str().ok())
        .unwrap_or(&format!("eip155:{CHAIN_ID}"))
        .to_string();
    let amount_str = resp
        .headers()
        .get("x-payment-amount")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("5000000")
        .to_string();
    let asset = resp
        .headers()
        .get("x-payment-asset")
        .and_then(|v| v.to_str().ok())
        .unwrap_or(USDC_ADDRESS)
        .to_string();
    let pay_to = resp
        .headers()
        .get("x-payment-payto")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();
    let amount_raw: u64 = amount_str.parse().unwrap_or(5_000_000);

    log_info(&format!(
        "  Paywall: {scheme} | ${:.2} USDC | network={network}",
        amount_raw as f64 / 1e6
    ));

    // Step 2: Sign EIP-3009 TransferWithAuthorization
    let chain_id: u64 = network
        .split(':')
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(CHAIN_ID);
    let valid_before = now_unix() + 300;

    let mut nonce_bytes = [0u8; 32];
    getrandom::getrandom(&mut nonce_bytes).expect("generate nonce");

    let (signature, nonce_hex) = sign_eip3009(
        &agent.signing_key,
        agent.wallet.address(),
        &pay_to,
        amount_raw,
        valid_before,
        &nonce_bytes,
        chain_id,
        &asset,
    );

    // Step 3: Settle via POST /x402/settle
    let settle_body = serde_json::json!({
        "paymentPayload": {
            "scheme": scheme,
            "network": network,
            "x402Version": 1,
            "payload": {
                "signature": signature,
                "authorization": {
                    "from": agent.wallet.address(),
                    "to": pay_to,
                    "value": amount_str,
                    "validAfter": "0",
                    "validBefore": valid_before.to_string(),
                    "nonce": nonce_hex,
                },
            },
        },
        "paymentRequired": {
            "scheme": scheme,
            "network": network,
            "amount": amount_str,
            "asset": asset,
            "payTo": pay_to,
            "maxTimeoutSeconds": 300,
        },
    });

    let contracts = fetch_contracts().await;
    let (auth_sig, auth_agent, auth_ts, auth_nonce) =
        sign_api_auth(&agent.signing_key, "POST", "/api/v1/x402/settle", &contracts.router);

    let settle_resp = client
        .post(&format!("{base}/x402/settle"))
        .header("X-Remit-Signature", &auth_sig)
        .header("X-Remit-Agent", &auth_agent)
        .header("X-Remit-Timestamp", &auth_ts)
        .header("X-Remit-Nonce", &auth_nonce)
        .json(&settle_body)
        .send()
        .await
        .expect("POST /x402/settle");

    let settle_data: serde_json::Value = settle_resp.json().await.expect("parse settle response");
    let tx_hash = settle_data["transactionHash"]
        .as_str()
        .unwrap_or("")
        .to_string();
    if tx_hash.is_empty() {
        results.fail(
            flow,
            &format!("settle returned no tx_hash: {settle_data}"),
        );
        return;
    }
    log_tx(flow, "settle", &tx_hash);

    // Step 4: Fetch weather with payment proof
    let weather_resp = client
        .get(&format!("{base}/x402/demo"))
        .header("X-Payment-Response", &tx_hash)
        .send()
        .await
        .expect("GET /x402/demo with payment");

    if weather_resp.status().as_u16() != 200 {
        results.fail(
            flow,
            &format!("weather fetch returned {}", weather_resp.status()),
        );
        return;
    }

    let weather: serde_json::Value = weather_resp.json().await.expect("parse weather");

    // Display weather report
    let loc = &weather["location"];
    let cur = &weather["current"];
    let cond = &cur["condition"];

    let city = loc["name"].as_str().unwrap_or("Unknown");
    let region = format!(
        "{}, {}",
        loc["region"].as_str().unwrap_or(""),
        loc["country"].as_str().unwrap_or("")
    );
    let temp_f = cur["temp_f"].as_f64().map_or("?".to_string(), |v| format!("{v:.0}"));
    let temp_c = cur["temp_c"].as_f64().map_or("?".to_string(), |v| format!("{v:.0}"));
    let condition = cond["text"]
        .as_str()
        .or_else(|| cur["condition"].as_str())
        .unwrap_or("Unknown");
    let humidity = cur["humidity"]
        .as_u64()
        .map_or("?".to_string(), |v| v.to_string());
    let wind_mph = cur["wind_mph"]
        .as_f64()
        .or_else(|| cur["wind_kph"].as_f64())
        .map_or("?".to_string(), |v| format!("{v:.0}"));
    let wind_dir = cur["wind_dir"].as_str().unwrap_or("");

    println!();
    println!("{CYAN}+---------------------------------------------+{RESET}");
    println!(
        "{CYAN}|{RESET}  {BOLD}x402 Weather Report{RESET} (paid ${:.2} USDC)   {CYAN}|{RESET}",
        amount_raw as f64 / 1e6
    );
    println!("{CYAN}+---------------------------------------------+{RESET}");
    println!("{CYAN}|{RESET}  City:        {city:<29}{CYAN}|{RESET}");
    println!("{CYAN}|{RESET}  Region:      {region:<29}{CYAN}|{RESET}");
    println!(
        "{CYAN}|{RESET}  Temperature: {temp_f} F / {temp_c} C{:<width$}{CYAN}|{RESET}",
        "",
        width = 21usize.saturating_sub(temp_f.len() + temp_c.len())
    );
    println!("{CYAN}|{RESET}  Condition:   {condition:<29}{CYAN}|{RESET}");
    println!(
        "{CYAN}|{RESET}  Humidity:    {humidity}%{:<width$}{CYAN}|{RESET}",
        "",
        width = 28usize.saturating_sub(humidity.len())
    );
    println!(
        "{CYAN}|{RESET}  Wind:        {wind_mph} mph {wind_dir}{:<width$}{CYAN}|{RESET}",
        "",
        width = 22usize.saturating_sub(wind_mph.len() + wind_dir.len())
    );
    println!("{CYAN}+---------------------------------------------+{RESET}");
    println!();

    results.pass(
        flow,
        &format!("city={city}, tx={}...", &tx_hash[..18.min(tx_hash.len())]),
    );
}

// ─── Flow 8: AP2 Discovery ──────────────────────────────────────────────────

async fn flow_ap2_discovery(results: &mut Results) {
    let flow = "8. AP2 Discovery";
    let card = AgentCard::discover(&api_url()).await.expect("discover");

    println!();
    println!("{CYAN}+---------------------------------------------+{RESET}");
    println!("{CYAN}|{RESET}  {BOLD}A2A Agent Card{RESET}                            {CYAN}|{RESET}");
    println!("{CYAN}+---------------------------------------------+{RESET}");
    println!(
        "{CYAN}|{RESET}  Name:     {:<32}{CYAN}|{RESET}",
        &card.name[..card.name.len().min(32)]
    );
    println!(
        "{CYAN}|{RESET}  Version:  {:<32}{CYAN}|{RESET}",
        &card.version[..card.version.len().min(32)]
    );
    println!(
        "{CYAN}|{RESET}  Protocol: {:<32}{CYAN}|{RESET}",
        &card.protocol_version[..card.protocol_version.len().min(32)]
    );
    println!(
        "{CYAN}|{RESET}  URL:      {:<32}{CYAN}|{RESET}",
        &card.url[..card.url.len().min(32)]
    );

    if !card.skills.is_empty() {
        println!(
            "{CYAN}|{RESET}  Skills:   {} total{:<25}{CYAN}|{RESET}",
            card.skills.len(),
            ""
        );
        for s in card.skills.iter().take(5) {
            let name = &s.name[..s.name.len().min(38)];
            println!("{CYAN}|{RESET}    - {name:<38}{CYAN}|{RESET}");
        }
    }

    let settle_ep = &card.x402.settle_endpoint;
    let x402_info = format!("settle={}", &settle_ep[..settle_ep.len().min(28)]);
    println!(
        "{CYAN}|{RESET}  x402:     {:<32}{CYAN}|{RESET}",
        &x402_info[..x402_info.len().min(32)]
    );

    let exts: Vec<String> = card
        .capabilities
        .extensions
        .iter()
        .map(|e| e.uri.split('/').last().unwrap_or("").to_string())
        .collect();
    let exts_str = if exts.is_empty() {
        "none".to_string()
    } else {
        exts.join(", ")
    };
    let caps_str = format!(
        "streaming={}, exts={}",
        card.capabilities.streaming,
        &exts_str[..exts_str.len().min(16)]
    );
    println!(
        "{CYAN}|{RESET}  Caps:     {:<32}{CYAN}|{RESET}",
        &caps_str[..caps_str.len().min(32)]
    );
    println!("{CYAN}+---------------------------------------------+{RESET}");
    println!();

    assert!(!card.name.is_empty(), "agent card should have a name");
    results.pass(flow, &format!("name={}", card.name));
}

// ─── Flow 9: AP2 Payment ───────────────────────────────────────────────────

async fn flow_ap2_payment(
    agent: &TestWallet,
    provider: &TestWallet,
    results: &mut Results,
) {
    let flow = "9. AP2 Payment";
    let card = AgentCard::discover(&api_url()).await.expect("discover");

    let signer = PrivateKeySigner::new(&agent.hex_key).expect("create signer");
    let a2a = A2AClient::from_card(&card, Arc::new(signer));

    let task = a2a
        .send(SendOptions {
            to: provider.wallet.address().to_string(),
            amount: 1.0,
            memo: Some("acceptance-ap2-payment".to_string()),
            mandate: None,
        })
        .await
        .expect("a2a send");

    assert!(!task.id.is_empty(), "a2a task should have an id");

    if let Some(tx_hash) = get_task_tx_hash(&task) {
        log_tx(flow, "a2a-pay", &tx_hash);
    }

    // Verify persistence
    let fetched = a2a.get_task(&task.id).await.expect("a2a get_task");
    assert_eq!(fetched.id, task.id, "fetched task id should match");

    results.pass(
        flow,
        &format!("task_id={}, state={}", task.id, task.status.state),
    );
}

// ─── Main ────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() {
    println!();
    println!("{BOLD}Rust SDK — 9 Flow Acceptance Suite{RESET}");
    println!("  API: {}", api_url());
    println!("  RPC: {}", rpc_url());
    println!();

    let contracts = fetch_contracts().await;
    let mut results = Results::new();

    // Setup wallets
    log_info("Creating agent wallet...");
    let agent = create_test_wallet(&contracts.router);
    log_info(&format!("  Agent:    {}", agent.wallet.address()));

    log_info("Creating provider wallet...");
    let provider = create_test_wallet(&contracts.router);
    log_info(&format!("  Provider: {}", provider.wallet.address()));

    log_info("Minting $100 USDC to agent...");
    fund_wallet(&agent, 100.0).await;
    let bal = get_usdc_balance(agent.wallet.address()).await;
    log_info(&format!("  Agent balance: ${bal:.2}"));

    log_info("Minting $100 USDC to provider...");
    fund_wallet(&provider, 100.0).await;
    let bal2 = get_usdc_balance(provider.wallet.address()).await;
    log_info(&format!("  Provider balance: ${bal2:.2}"));
    println!();

    // Permit nonce counter — each permit consumed on-chain increments the nonce
    let mut permit_nonce: u64 = 0;

    // Run flows sequentially
    // Each flow internally handles its own [PASS]/[FAIL] logging.
    // If a flow panics, it will abort the entire suite (acceptable for acceptance tests).
    // For graceful error handling within flows, each flow uses .expect() on
    // critical operations — failures are visible in the output.
    flow_direct(&agent, &provider, &contracts, &mut results, &mut permit_nonce).await;
    flow_escrow(&agent, &provider, &contracts, &mut results, &mut permit_nonce).await;
    flow_tab(&agent, &provider, &contracts, &mut results, &mut permit_nonce).await;
    flow_stream(&agent, &provider, &contracts, &mut results, &mut permit_nonce).await;
    flow_bounty(&agent, &provider, &contracts, &mut results, &mut permit_nonce).await;
    flow_deposit(&agent, &provider, &contracts, &mut results, &mut permit_nonce).await;
    flow_x402_weather(&agent, &mut results).await;
    flow_ap2_discovery(&mut results).await;
    flow_ap2_payment(&agent, &provider, &mut results).await;

    // Summary
    let passed = results.passed();
    let failed = results.failed();
    let skipped = 9 - passed - failed;

    println!();
    println!("{BOLD}Rust Summary: {GREEN}{passed} passed{RESET}, {RED}{failed} failed{RESET} / 9 flows");
    println!(
        "{}",
        serde_json::json!({
            "passed": passed,
            "failed": failed,
            "skipped": skipped,
        })
    );

    if failed > 0 {
        std::process::exit(1);
    }
}
