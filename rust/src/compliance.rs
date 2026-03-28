// Compliance tests: Rust SDK against a real running server.
//
// Tests are skipped when the server is not reachable. Boot the server with:
//   docker compose -f docker-compose.compliance.yml up -d
//
// Environment variables:
//   REMIT_TEST_SERVER_URL  (default: http://localhost:3000)
//   REMIT_ROUTER_ADDRESS   (default: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8)
//
// Run compliance tests specifically:
//   cargo test compliance -- --include-ignored

#[cfg(test)]
mod compliance_tests {
    use crate::Wallet;
    use rust_decimal::Decimal;
    use std::str::FromStr;
    use std::sync::OnceLock;

    fn server_url() -> &'static str {
        static URL: OnceLock<String> = OnceLock::new();
        URL.get_or_init(|| {
            std::env::var("REMIT_TEST_SERVER_URL")
                .unwrap_or_else(|_| "http://localhost:3000".to_string())
        })
    }

    fn router_address() -> &'static str {
        static ADDR: OnceLock<String> = OnceLock::new();
        ADDR.get_or_init(|| {
            std::env::var("REMIT_ROUTER_ADDRESS")
                .unwrap_or_else(|_| "0x70997970C51812dc3A010C7d01b50e0d17dc79C8".to_string())
        })
    }

    /// Returns false if the compliance server is not reachable.
    async fn is_server_available() -> bool {
        eprintln!("[COMPLIANCE] checking server availability at {}/health", server_url());
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(3))
            .build()
            .expect("build http client");
        match client.get(format!("{}/health", server_url())).send().await {
            Ok(r) => {
                let ok = r.status().as_u16() == 200;
                eprintln!("[COMPLIANCE] server health check: status={}, available={}", r.status(), ok);
                ok
            }
            Err(e) => {
                eprintln!("[COMPLIANCE] server health check failed: {}", e);
                false
            }
        }
    }

    /// Generate a random private key and derive the wallet address.
    /// No server registration needed - the new auth model uses EIP-712 signatures.
    fn generate_wallet() -> (String, String) {
        use rand_core::{OsRng, RngCore};
        let mut key_bytes = [0u8; 32];
        OsRng.fill_bytes(&mut key_bytes);
        let private_key = format!("0x{}", hex::encode(key_bytes));
        let wallet = make_wallet(&private_key);
        let addr = wallet.address().to_string();
        eprintln!("[COMPLIANCE] wallet generated: {} (chain={})", addr, wallet.chain_id());
        (private_key, addr)
    }

    /// Fund a wallet via mint (no auth required in testnet mode).
    async fn fund_wallet(client: &reqwest::Client, wallet_addr: &str) {
        eprintln!("[COMPLIANCE] minting 1000 USDC to {}", wallet_addr);
        let resp: serde_json::Value = client
            .post(format!("{}/api/v1/mint", server_url()))
            .json(&serde_json::json!({ "wallet": wallet_addr, "amount": 1000 }))
            .send()
            .await
            .expect("mint POST")
            .json()
            .await
            .expect("mint JSON");
        assert!(
            resp["tx_hash"].is_string(),
            "mint response must contain tx_hash, got: {resp}"
        );
        eprintln!("[COMPLIANCE] mint: 1000 USDC -> {} tx={}", wallet_addr, resp["tx_hash"]);
    }

    fn make_wallet(private_key: &str) -> Wallet {
        let w = Wallet::new(private_key)
            .chain("base")
            .testnet()
            .base_url(server_url())
            .router_address(router_address())
            .build()
            .expect("build wallet");
        eprintln!("[COMPLIANCE] wallet created: {} (chain={}, base_url={})", w.address(), w.chain_id(), server_url());
        w
    }

    // ─── Shared funded payer ─────────────────────────────────────────────────

    static SHARED_PAYER_KEY: OnceLock<String> = OnceLock::new();
    static SHARED_PAYER_ADDR: OnceLock<String> = OnceLock::new();

    async fn get_shared_payer(client: &reqwest::Client) -> Wallet {
        let key = if let Some(k) = SHARED_PAYER_KEY.get() {
            eprintln!("[COMPLIANCE] reusing shared payer wallet (already funded)");
            k.clone()
        } else {
            eprintln!("[COMPLIANCE] creating new shared payer wallet");
            let (pk, addr) = generate_wallet();
            fund_wallet(client, &addr).await;
            // OnceLock::set returns Err if already set - that's fine, another task beat us.
            let _ = SHARED_PAYER_KEY.set(pk.clone());
            let _ = SHARED_PAYER_ADDR.set(addr.clone());
            eprintln!("[COMPLIANCE] shared payer ready: {}", addr);
            pk
        };
        make_wallet(&key)
    }

    // ─── Auth tests ───────────────────────────────────────────────────────────

    #[tokio::test]
    #[ignore = "requires compliance server"]
    async fn compliance_authenticated_request_returns_balance_not_401() {
        eprintln!("[COMPLIANCE] === test: authenticated_request_returns_balance_not_401 ===");
        if !is_server_available().await {
            eprintln!("SKIP: compliance server not reachable");
            return;
        }
        let client = reqwest::Client::new();
        let wallet = get_shared_payer(&client).await;

        // reputation() makes an authenticated GET to /api/v1/reputation/{address} -
        // this endpoint exists for all registered addresses and fails with 401 if
        // auth headers are wrong.
        eprintln!("[COMPLIANCE] fetching reputation for {}", wallet.address());
        let rep = wallet
            .reputation(wallet.address())
            .await
            .expect("reputation() must not fail with valid auth");
        eprintln!("[COMPLIANCE] reputation returned successfully for {}: {:?}", wallet.address(), rep);
    }

    #[tokio::test]
    #[ignore = "requires compliance server"]
    async fn compliance_unauthenticated_request_returns_401() {
        eprintln!("[COMPLIANCE] === test: unauthenticated_request_returns_401 ===");
        if !is_server_available().await {
            eprintln!("SKIP: compliance server not reachable");
            return;
        }
        let client = reqwest::Client::new();
        eprintln!("[COMPLIANCE] sending unauthenticated POST to /api/v1/payments/direct");
        let resp = client
            .post(format!("{}/api/v1/payments/direct", server_url()))
            .json(&serde_json::json!({
                "to": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
                "amount": "1.000000"
            }))
            .send()
            .await
            .expect("POST /payments/direct");
        eprintln!("[COMPLIANCE] unauthenticated response: status={}", resp.status());
        assert_eq!(
            resp.status().as_u16(),
            401,
            "unauthenticated request must return 401"
        );
        eprintln!("[COMPLIANCE] confirmed: unauthenticated request correctly returned 401");
    }

    // ─── Payment tests ────────────────────────────────────────────────────────

    #[tokio::test]
    #[ignore = "requires compliance server"]
    async fn compliance_pay_direct_happy_path_returns_tx_hash() {
        eprintln!("[COMPLIANCE] === test: pay_direct_happy_path_returns_tx_hash ===");
        if !is_server_available().await {
            eprintln!("SKIP: compliance server not reachable");
            return;
        }
        let client = reqwest::Client::new();
        let payer = get_shared_payer(&client).await;
        let (_payee_key, payee_addr) = generate_wallet();

        eprintln!("[COMPLIANCE] pay: 5.0 USDC {} -> {} memo=\"rust compliance test\"", payer.address(), payee_addr);
        let tx = payer
            .pay_with_memo(
                &payee_addr,
                Decimal::from_str("5.0").unwrap(),
                "rust compliance test",
            )
            .await
            .expect("pay_with_memo must succeed");

        eprintln!("[COMPLIANCE] pay: 5.0 USDC {} -> {} tx={} id={}", payer.address(), payee_addr, tx.tx_hash, tx.id);
        assert!(
            !tx.tx_hash.is_empty(),
            "pay() must return a non-empty tx_hash"
        );
        eprintln!("[COMPLIANCE] confirmed: tx_hash is non-empty");
    }

    #[tokio::test]
    #[ignore = "requires compliance server"]
    async fn compliance_pay_direct_below_minimum_returns_error() {
        eprintln!("[COMPLIANCE] === test: pay_direct_below_minimum_returns_error ===");
        if !is_server_available().await {
            eprintln!("SKIP: compliance server not reachable");
            return;
        }
        let client = reqwest::Client::new();
        let payer = get_shared_payer(&client).await;
        let (_payee_key, payee_addr) = generate_wallet();

        eprintln!("[COMPLIANCE] pay: 0.0001 USDC {} -> {} (expect error: below minimum)", payer.address(), payee_addr);
        let result = payer
            .pay(&payee_addr, Decimal::from_str("0.0001").unwrap())
            .await;

        match &result {
            Ok(tx) => eprintln!("[COMPLIANCE] pay unexpectedly succeeded: tx={}", tx.tx_hash),
            Err(e) => eprintln!("[COMPLIANCE] pay correctly rejected: {}", e),
        }
        assert!(
            result.is_err(),
            "pay() with amount below minimum must return an error"
        );
        eprintln!("[COMPLIANCE] confirmed: below-minimum payment was rejected");
    }
}
