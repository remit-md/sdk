use std::collections::HashMap;
use thiserror::Error;

const DOC_BASE: &str = "https://remit.md/docs/errors#";

/// Stable, machine-readable error codes. These never change across SDK versions.
pub mod codes {
    pub const INVALID_ADDRESS: &str = "INVALID_ADDRESS";
    pub const INVALID_AMOUNT: &str = "INVALID_AMOUNT";
    pub const INSUFFICIENT_FUNDS: &str = "INSUFFICIENT_FUNDS";
    pub const ESCROW_NOT_FOUND: &str = "ESCROW_NOT_FOUND";
    pub const ESCROW_ALREADY_FUNDED: &str = "ESCROW_ALREADY_FUNDED";
    pub const ESCROW_NOT_FUNDED: &str = "ESCROW_NOT_FUNDED";
    pub const ESCROW_EXPIRED: &str = "ESCROW_EXPIRED";
    pub const TAB_NOT_FOUND: &str = "TAB_NOT_FOUND";
    pub const TAB_CLOSED: &str = "TAB_CLOSED";
    pub const TAB_LIMIT_EXCEEDED: &str = "TAB_LIMIT_EXCEEDED";
    pub const STREAM_NOT_FOUND: &str = "STREAM_NOT_FOUND";
    pub const STREAM_CLOSED: &str = "STREAM_CLOSED";
    pub const BOUNTY_NOT_FOUND: &str = "BOUNTY_NOT_FOUND";
    pub const BOUNTY_EXPIRED: &str = "BOUNTY_EXPIRED";
    pub const DEPOSIT_NOT_FOUND: &str = "DEPOSIT_NOT_FOUND";
    pub const SPENDING_LIMIT_HIT: &str = "SPENDING_LIMIT_HIT";
    pub const RATE_LIMITED: &str = "RATE_LIMITED";
    pub const UNAUTHORIZED: &str = "UNAUTHORIZED";
    pub const NETWORK_ERROR: &str = "NETWORK_ERROR";
    pub const SERVER_ERROR: &str = "SERVER_ERROR";
    pub const INVALID_SIGNATURE: &str = "INVALID_SIGNATURE";
    pub const CHAIN_MISMATCH: &str = "CHAIN_MISMATCH";
    pub const INVALID_KEY: &str = "INVALID_KEY";
}

/// Structured error type returned by all SDK methods.
///
/// Every error has a stable machine-readable `code`, an actionable `message`
/// that tells the agent exactly how to fix the problem, and a `doc_url` linking
/// to the specific error's remediation guide.
///
/// # Matching on error codes
///
/// ```rust,ignore
/// use remitmd::{RemitError, error::codes};
///
/// if let Err(e) = result {
///     match e.code.as_str() {
///         codes::INSUFFICIENT_FUNDS => println!("need more USDC: {}", e.message),
///         codes::INVALID_ADDRESS => println!("bad address: {}", e.message),
///         _ => println!("error: {e}"),
///     }
/// }
/// ```
#[derive(Debug, Clone, Error)]
#[error("remitmd: {code} — {message} (see: {doc_url})")]
pub struct RemitError {
    /// Stable machine-readable code (e.g., `"INVALID_ADDRESS"`).
    pub code: String,
    /// Actionable message explaining the error and how to fix it.
    pub message: String,
    /// Direct link to documentation for this error code.
    pub doc_url: String,
    /// Structured context values (offending input, limits, etc.).
    pub context: HashMap<String, serde_json::Value>,
}

impl RemitError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_string(),
            message: message.into(),
            doc_url: format!("{DOC_BASE}{code}"),
            context: HashMap::new(),
        }
    }

    pub fn with_context(mut self, key: &str, value: impl Into<serde_json::Value>) -> Self {
        self.context.insert(key.to_string(), value.into());
        self
    }
}

/// Shorthand constructor used internally.
pub(crate) fn remit_err(code: &str, message: impl Into<String>) -> RemitError {
    RemitError::new(code, message)
}

/// Shorthand constructor with a single context key-value pair.
pub(crate) fn remit_err_ctx(
    code: &str,
    message: impl Into<String>,
    key: &str,
    value: impl Into<serde_json::Value>,
) -> RemitError {
    RemitError::new(code, message).with_context(key, value)
}
