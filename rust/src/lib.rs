//! # remitmd — Rust SDK for the remit.md universal AI payment protocol
//!
//! remit.md enables AI agents to send and receive USDC payments on Base (EVM L2)
//! with support for direct payments, escrow, streaming, payment channels (tabs),
//! bounties, and security deposits.
//!
//! ## Quick start
//!
//! ```rust,no_run
//! use remitmd::Wallet;
//! use rust_decimal_macros::dec;
//!
//! #[tokio::main]
//! async fn main() -> Result<(), Box<dyn std::error::Error>> {
//!     // From environment: export REMITMD_KEY=0x...
//!     let wallet = Wallet::from_env()?;
//!
//!     // Direct payment
//!     let tx = wallet.pay("0xRecipient...", dec!(1.50)).await?;
//!     println!("paid {:?} USDC in {}", tx.amount, tx.tx_hash);
//!
//!     // Escrow for high-value work
//!     let escrow = wallet.create_escrow("0xAgent...", dec!(100.00)).await?;
//!     // ... agent completes work ...
//!     wallet.release_escrow(&escrow.id, None).await?;
//!     Ok(())
//! }
//! ```
//!
//! ## Testing
//!
//! Use `MockRemit` for unit tests — zero network, zero latency, deterministic:
//!
//! ```rust
//! use remitmd::MockRemit;
//! use rust_decimal_macros::dec;
//!
//! #[tokio::test]
//! async fn agent_pays_for_service() {
//!     let mock = MockRemit::new();
//!     let wallet = mock.wallet();
//!
//!     wallet.pay("0xService000000000000000000000000000000001", dec!(0.003)).await.unwrap();
//!
//!     assert!(mock.was_paid("0xService000000000000000000000000000000001", dec!(0.003)).await);
//! }
//! ```
//!
//! ## Error handling
//!
//! All SDK methods return `Result<T, RemitError>`. Errors are structured with a
//! stable machine-readable code, an actionable message, and a documentation link.
//!
//! ```rust,ignore
//! use remitmd::error::codes;
//!
//! match wallet.pay(addr, amount).await {
//!     Ok(tx) => println!("paid: {}", tx.tx_hash),
//!     Err(e) if e.code == codes::INVALID_ADDRESS => {
//!         eprintln!("fix the address: {}", e.message);
//!     }
//!     Err(e) if e.code == codes::INSUFFICIENT_BALANCE => {
//!         eprintln!("top up your wallet: {}", e.message);
//!     }
//!     Err(e) => eprintln!("payment error: {e}"),
//! }
//! ```

#![deny(warnings)]

pub mod a2a;
mod compliance;
pub mod error;
mod http;
pub mod http_signer;
mod mock;
mod models;
mod signer;
mod wallet;
pub mod x402;

// ─── Public API ───────────────────────────────────────────────────────────────

pub use error::RemitError;
pub use http_signer::HttpSigner;
pub use mock::MockRemit;
pub use models::{
    Balance, Bounty, BountyStatus, BountySubmission, Budget, ChainId, ContractAddresses, Deposit,
    DepositStatus, Escrow, EscrowStatus, Intent, Milestone, MintResponse, PermitSignature,
    Reputation, SpendingSummary, Split, Stream, StreamStatus, Tab, TabCharge, TabDebit, TabStatus,
    TopRecipient, Transaction, TransactionList, WalletStatus,
};
pub use signer::{PrivateKeySigner, Signer};
pub use wallet::{Wallet, WalletBuilder, WithKey, WithSigner};
