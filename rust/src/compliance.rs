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
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(3))
            .build()
            .expect("build http client");
        match client.get(format!("{}/health", server_url())).send().await {
            Ok(r) => r.status().as_u16() == 200,
            Err(_) => false,
        }
    }

    /// Register a new operator. Returns (private_key, wallet_address).
    async fn register_and_get_key(client: &reqwest::Client) -> (String, String) {
        let email = format!(
            "compliance.rust.{}@test.remitmd.local",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_millis()
        );
        let reg: serde_json::Value = client
            .post(format!("{}/api/v0/auth/register", server_url()))
            .json(&serde_json::json!({ "email": email, "password": "ComplianceTestPass1!" }))
            .send()
            .await
            .expect("register POST")
            .json()
            .await
            .expect("register JSON");

        let token = reg["token"].as_str().expect("token in register response");
        let wallet_addr = reg["wallet_address"]
            .as_str()
            .expect("wallet_address in register response")
            .to_string();

        let key_data: serde_json::Value = client
            .get(format!("{}/api/v0/auth/agent-key", server_url()))
            .header("Authorization", format!("Bearer {}", token))
            .send()
            .await
            .expect("agent-key GET")
            .json()
            .await
            .expect("agent-key JSON");

        let private_key = key_data["private_key"]
            .as_str()
            .expect("private_key in agent-key response")
            .to_string();

        (private_key, wallet_addr)
    }

    /// Fund a wallet via the faucet (no auth required in testnet mode).
    async fn fund_wallet(client: &reqwest::Client, wallet_addr: &str) {
        let resp: serde_json::Value = client
            .post(format!("{}/api/v0/faucet", server_url()))
            .json(&serde_json::json!({ "wallet": wallet_addr, "amount": 1000 }))
            .send()
            .await
            .expect("faucet POST")
            .json()
            .await
            .expect("faucet JSON");
        assert!(
            resp["tx_hash"].is_string(),
            "faucet response must contain tx_hash, got: {resp}"
        );
    }

    fn make_wallet(private_key: &str) -> Wallet {
        Wallet::new(private_key)
            .chain("base")
            .testnet()
            .base_url(server_url())
            .router_address(router_address())
            .build()
            .expect("build wallet")
    }

    // ─── Shared funded payer ─────────────────────────────────────────────────

    static SHARED_PAYER_KEY: OnceLock<String> = OnceLock::new();
    static SHARED_PAYER_ADDR: OnceLock<String> = OnceLock::new();

    async fn get_shared_payer(client: &reqwest::Client) -> Wallet {
        let key = if let Some(k) = SHARED_PAYER_KEY.get() {
            k.clone()
        } else {
            let (pk, addr) = register_and_get_key(client).await;
            fund_wallet(client, &addr).await;
            // OnceLock::set returns Err if already set — that's fine, another task beat us.
            let _ = SHARED_PAYER_KEY.set(pk.clone());
            let _ = SHARED_PAYER_ADDR.set(addr);
            pk
        };
        make_wallet(&key)
    }

    // ─── Auth tests ───────────────────────────────────────────────────────────

    #[tokio::test]
    #[ignore = "requires compliance server"]
    async fn compliance_authenticated_request_returns_balance_not_401() {
        if !is_server_available().await {
            eprintln!("SKIP: compliance server not reachable");
            return;
        }
        let client = reqwest::Client::new();
        let (pk, _addr) = register_and_get_key(&client).await;
        let wallet = make_wallet(&pk);

        let balance = wallet
            .balance()
            .await
            .expect("balance() must not fail with valid auth");
        // Server returns a balance object — we just verify the call succeeded (no 401).
        let _ = balance;
    }

    #[tokio::test]
    #[ignore = "requires compliance server"]
    async fn compliance_unauthenticated_request_returns_401() {
        if !is_server_available().await {
            eprintln!("SKIP: compliance server not reachable");
            return;
        }
        let client = reqwest::Client::new();
        let resp = client
            .post(format!("{}/api/v0/payments/direct", server_url()))
            .json(&serde_json::json!({
                "to": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
                "amount": "1.000000"
            }))
            .send()
            .await
            .expect("POST /payments/direct");
        assert_eq!(
            resp.status().as_u16(),
            401,
            "unauthenticated request must return 401"
        );
    }

    // ─── Payment tests ────────────────────────────────────────────────────────

    #[tokio::test]
    #[ignore = "requires compliance server"]
    async fn compliance_pay_direct_happy_path_returns_tx_hash() {
        if !is_server_available().await {
            eprintln!("SKIP: compliance server not reachable");
            return;
        }
        let client = reqwest::Client::new();
        let payer = get_shared_payer(&client).await;
        let (_payee_key, payee_addr) = register_and_get_key(&client).await;

        let tx = payer
            .pay_with_memo(
                &payee_addr,
                Decimal::from_str("5.0").unwrap(),
                "rust compliance test",
            )
            .await
            .expect("pay_with_memo must succeed");

        assert!(
            !tx.tx_hash.is_empty(),
            "pay() must return a non-empty tx_hash"
        );
    }

    #[tokio::test]
    #[ignore = "requires compliance server"]
    async fn compliance_pay_direct_below_minimum_returns_error() {
        if !is_server_available().await {
            eprintln!("SKIP: compliance server not reachable");
            return;
        }
        let client = reqwest::Client::new();
        let payer = get_shared_payer(&client).await;
        let (_payee_key, payee_addr) = register_and_get_key(&client).await;

        let result = payer
            .pay(&payee_addr, Decimal::from_str("0.0001").unwrap())
            .await;

        assert!(
            result.is_err(),
            "pay() with amount below minimum must return an error"
        );
    }
}
