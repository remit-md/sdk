# remitmd — Rust SDK

> [Skill MD](https://remit.md) · [Docs](https://remit.md/docs) · [Agent Spec](https://remit.md/agent.md)

[![CI](https://github.com/remit-md/sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/remit-md/sdk/actions/workflows/ci.yml)

Rust SDK for the [remit.md](https://remit.md) universal AI payment protocol. Send and receive USDC payments from AI agents on Base using Tokio async.

## Install

```toml
# Cargo.toml
[dependencies]
remitmd = "0.1"
tokio = { version = "1", features = ["rt-multi-thread", "macros"] }
rust_decimal_macros = "1"  # optional: dec!() macro for literals
```

## 3-line integration

```rust
use remitmd::Wallet;
use rust_decimal_macros::dec;

let wallet = Wallet::from_env()?;                            // REMITMD_KEY env var
let tx = wallet.pay("0xAgent...", dec!(1.50)).await?;       // send USDC
println!("paid {} in {}", tx.amount, tx.tx_hash);
```

## Configuration

```rust
// From environment variables (recommended for agents)
let wallet = Wallet::from_env()?;
// REMITMD_KEY=0x...         (required)
// REMITMD_CHAIN=base        (optional, default: "base")
// REMITMD_TESTNET=true      (optional)
// REMITMD_RPC_URL=https://… (optional, for permit nonce fetching)

// Builder pattern
let wallet = Wallet::new("0x<private-key>")
    .chain("base")          // "base" (only supported chain)
    .testnet()              // use testnet
    .base_url("http://localhost:3000")  // self-hosted
    .rpc_url("https://sepolia.base.org") // custom RPC
    .build()?;

// Custom signer (KMS, hardware wallet, etc.)
let wallet = Wallet::with_signer(my_kms_signer)
    .chain("base")
    .build()?;
```

All payment methods (`pay`, `create_escrow`, `create_tab`, `create_stream`, `create_bounty`, `lock_deposit`) automatically sign an EIP-2612 permit for gasless USDC approval. No manual permit handling needed.

## Payment Models

### Direct Payment
```rust
// One-way transfer, no escrow
let tx = wallet.pay("0xAgent...", dec!(0.003)).await?;
let tx = wallet.pay_with_memo("0xAgent...", dec!(0.003), "API call fee").await?;
```

### Escrow
```rust
// Lock funds until work is verified
let escrow = wallet.create_escrow("0xContractor...", dec!(100.00)).await?;

// Optional: with milestones, splits, expiry
let escrow = wallet.create_escrow_full(
    "0xContractor...",
    dec!(100.00),
    "Build a data pipeline",
    &[Milestone { description: "Schema design".into(), amount: dec!(30.00), ..Default::default() }],
    &[],
    Some(7 * 24 * 3600), // expires in 7 days
).await?;

wallet.release_escrow(&escrow.id, None).await?;    // release all
wallet.release_escrow(&escrow.id, Some("milestone_id")).await?;  // release milestone
wallet.cancel_escrow(&escrow.id).await?;            // cancel, refund payer
let state = wallet.get_escrow(&escrow.id).await?;  // check status
```

### Tab (Payment Channel)
```rust
// Batch micro-payments off-chain, settle once on-chain
let tab = wallet.create_tab("0xService...", dec!(10.00), dec!(0.003)).await?;

// Provider charges the tab (with EIP-712 signature)
wallet.charge_tab(&tab.id, 0.003, 0.009, 3, &provider_sig).await?;

// Close when done — unused funds return
wallet.close_tab(&tab.id, 0.009, &provider_sig).await?;
```

### Stream
```rust
// Per-second payment flow (subscriptions, uptime billing)
let stream = wallet.create_stream(
    "0xProvider...",
    dec!(0.001),    // 0.001 USDC/sec
    dec!(100.00),   // 100 USDC deposited (~27 hours)
).await?;

wallet.withdraw_stream(&stream.id).await?;  // recipient claims vested funds
```

### Bounty
```rust
// Open reward for task completion
let bounty = wallet.create_bounty(dec!(5.00), "find cheapest RPC endpoint").await?;
wallet.award_bounty(&bounty.id, "0xWinner...").await?;
```

### Deposit
```rust
// Security collateral (lock, forfeit, or return)
let deposit = wallet.lock_deposit("0xBeneficiary...", dec!(20.00), 86_400).await?;
```

## Analytics & Reputation

```rust
// On-chain reputation (0-1000 score)
let rep = wallet.reputation("0xAgent...").await?;
println!("score: {}/1000", rep.score);

// Spending analytics
let summary = wallet.spending_summary("month").await?;   // "day", "week", "month", "all"
println!("{} USDC spent, {} transactions", summary.total_spent, summary.tx_count);

// Operator spending limits
let budget = wallet.remaining_budget().await?;
println!("daily remaining: {} USDC", budget.daily_remaining);

// Transaction history
let history = wallet.history(1, 50).await?;
```

## Testing with MockRemit

`MockRemit` is an in-memory mock with zero network dependencies. It's the fastest way to test agents that send payments.

```rust
use remitmd::MockRemit;
use rust_decimal_macros::dec;

#[tokio::test]
async fn agent_pays_for_api_call() {
    let mock = MockRemit::new();
    let wallet = mock.wallet();

    // Run your agent code
    wallet.pay("0xService0000000000000000000000000000001", dec!(0.003)).await.unwrap();

    // Assert payment behavior
    assert!(mock.was_paid("0xService0000000000000000000000000000001", dec!(0.003)).await);
    assert_eq!(mock.total_paid_to("0xService0000000000000000000000000000001").await, dec!(0.003));
    assert_eq!(mock.transaction_count().await, 1);
}

#[tokio::test]
async fn agent_handles_insufficient_funds() {
    let mock = MockRemit::with_balance(dec!(0.50));  // custom starting balance
    let wallet = mock.wallet();

    let err = wallet.pay("0xService...", dec!(1.00)).await.unwrap_err();
    assert_eq!(err.code, remitmd::error::codes::INSUFFICIENT_FUNDS);
}

#[tokio::test]
async fn full_escrow_lifecycle() {
    let mock = MockRemit::new();
    let wallet = mock.wallet();

    let escrow = wallet.create_escrow("0xContractor...", dec!(100.00)).await.unwrap();
    assert_eq!(mock.balance().await, dec!(9900.00));

    wallet.release_escrow(&escrow.id, None).await.unwrap();
    // clean up between test cases
    mock.reset().await;
}
```

## Additional Methods

```rust
// Contract discovery (cached per session)
let contracts = wallet.get_contracts().await?;

// Webhooks
wallet.register_webhook("https://...", &["payment.received"], None).await?;

// Operator links (_with_options variant accepts messages + agent_name)
let link = wallet.create_fund_link().await?;
let link = wallet.create_withdraw_link_with_options(&["Withdraw"], Some("my-agent")).await?;

// Testnet funding
let result = wallet.mint(100.0).await?;  // $100 testnet USDC
```

## Error Handling

All errors are typed `RemitError` with a stable `code`, an actionable `message`, and a `doc_url`. Enriched errors include actual numbers:

```rust
use remitmd::error::codes;

match wallet.pay(address, amount).await {
    Ok(tx) => println!("paid: {}", tx.tx_hash),
    Err(e) if e.code == codes::INSUFFICIENT_FUNDS => {
        // e.message: "Insufficient USDC balance: have $5.00, need $100.00"
        eprintln!("need more USDC: {}", e.message);
    }
    Err(e) if e.code == codes::INVALID_ADDRESS => {
        eprintln!("fix the address: {}", e.message);
    }
    Err(e) => eprintln!("error [{}]: {} (see: {})", e.code, e.message, e.doc_url),
}
```

## Advanced: Manual Permits

By default, all payment methods auto-sign EIP-2612 permits. If you need manual control:

```rust
// Sign a permit yourself
let permit = wallet.sign_permit("0xContractAddr...", 1.50, None).await?;

// Pass it explicitly to any _with_permit or _full variant
let tx = wallet.pay_with_permit("0xAgent...", dec!(0.003), permit).await?;
let tx = wallet.pay_full("0xAgent...", dec!(0.003), "memo", Some(permit)).await?;
```

Manual permit variants: `pay_with_permit`, `create_escrow_with_permit`, `create_tab_with_permit`, `create_stream_with_permit`, `create_bounty_with_permit`, `lock_deposit_with_permit`.

## License

MIT — [remit.md](https://remit.md)
