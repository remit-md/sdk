//! # remitmd Rust SDK -- Quick Start
//!
//! This example shows the core payment patterns for AI agents.
//! Run with: `cargo run --example quickstart`
//!
//! For tests, use MockRemit (no network required):
//! ```rust
//! let mock = remitmd::MockRemit::new();
//! let wallet = mock.wallet();
//! ```

use remitmd::MockRemit;
use rust_decimal_macros::dec;
use std::time::{SystemTime, UNIX_EPOCH};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // ─── Option 1: From environment ───────────────────────────────────────────
    // Set REMITMD_KEY, REMITMD_CHAIN, REMITMD_TESTNET before running.
    //
    // let wallet = Wallet::from_env()?;

    // ─── Option 2: Builder pattern ────────────────────────────────────────────
    // let wallet = Wallet::new("0x<private-key>")
    //     .chain("base")
    //     .testnet()
    //     .build()?;

    // ─── MockRemit for testing (no network, no key) ───────────────────────────
    println!("=== remitmd Rust SDK Quick Start (MockRemit) ===\n");

    let mock = MockRemit::new();
    let wallet = mock.wallet();

    let recipient = "0x0000000000000000000000000000000000000001";
    let payee = "0x0000000000000000000000000000000000000002";

    // 1. Check balance
    let bal = wallet.balance().await?;
    println!("Balance: {} USDC (address: {})", bal.usdc, bal.address);

    // 2. Direct payment -- one-way, instant, no escrow
    let tx = wallet.pay(recipient, dec!(1.50)).await?;
    println!(
        "\n[Direct] Paid {} USDC -> {} (tx: {})",
        tx.amount, tx.to, tx.id
    );

    // Verify with mock assertions
    assert!(mock.was_paid(recipient, dec!(1.50)).await);
    assert_eq!(mock.total_paid_to(recipient).await, dec!(1.50));

    // 3. Escrow -- lock funds, release on delivery
    let escrow = wallet.create_escrow(payee, dec!(100.00)).await?;
    println!(
        "\n[Escrow] Created {} (status: {:?})",
        escrow.id, escrow.status
    );

    // Agent completes work...
    let release_result = wallet.release_escrow(&escrow.id, None).await?;
    println!(
        "[Escrow] Released {} USDC -> {}",
        release_result.amount, release_result.payee
    );

    // 4. Tab -- payment channel for micro-payments
    let tab = wallet.create_tab(payee, dec!(10.00), dec!(0.10)).await?;
    println!(
        "\n[Tab] Opened {} (limit: {} USDC)",
        tab.id, tab.limit_amount
    );

    let closed = wallet.close_tab(&tab.id, 0.10, "0x00").await?;
    println!("[Tab] Closed: status={:?}", closed.status);

    // 5. Stream -- per-second payment flow
    let stream = wallet
        .create_stream(recipient, dec!(0.001), dec!(50.00))
        .await?;
    println!(
        "\n[Stream] Started {} ({} USDC/sec)",
        stream.id, stream.rate_per_second
    );

    // 6. Bounty -- open reward for task completion
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let bounty = wallet
        .create_bounty(dec!(5.00), "Find cheapest Base RPC endpoint", now + 3600)
        .await?;
    println!(
        "\n[Bounty] Posted {} (amount: {} USDC)",
        bounty.id, bounty.amount
    );

    let awarded = wallet.award_bounty(&bounty.id, 1).await?;
    println!("[Bounty] Awarded: status={:?}", awarded.status);

    // 7. Deposit -- security collateral
    let deposit = wallet
        .lock_deposit(payee, dec!(20.00), now + 86_400)
        .await?;
    println!(
        "\n[Deposit] Locked {} (status: {:?})",
        deposit.id, deposit.status
    );

    // 8. Reputation check
    let rep = wallet.reputation(recipient).await?;
    println!(
        "\n[Reputation] {} score: {}/1000 ({} txs)",
        rep.address, rep.score, rep.transaction_count
    );

    // 9. Spending summary
    let summary = wallet.spending_summary("month").await?;
    println!(
        "\n[Analytics] {} USDC spent this month across {} transactions",
        summary.total_spent, summary.tx_count
    );

    // 10. Budget / operator limits
    let budget = wallet.remaining_budget().await?;
    println!("[Budget] Daily remaining: {} USDC", budget.daily_remaining);

    println!("\nAll patterns demonstrated successfully.");
    Ok(())
}
