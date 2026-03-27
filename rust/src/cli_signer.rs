//! CLI signer adapter for the `remit sign` subprocess.
//!
//! Delegates digest signing to the Remit CLI binary. The CLI holds the encrypted
//! keystore; this adapter only needs the binary on PATH and the `REMIT_KEY_PASSWORD`
//! env var set.
//!
//! # Usage
//!
//! ```rust,ignore
//! use remitmd::CliSigner;
//! use remitmd::Wallet;
//!
//! let signer = CliSigner::new()?;
//! let wallet = Wallet::with_signer(signer).testnet().build()?;
//! ```

use std::io::Write;
use std::process::{Command, Stdio};

use crate::error::{codes, remit_err, RemitError};
use crate::signer::Signer;

/// Signer backed by the `remit sign` CLI command.
///
/// - No key material in this process — signing happens in a subprocess.
/// - Address is cached at construction time via `remit address`.
/// - `sign()` pipes a hex digest to `remit sign --digest` on stdin.
/// - All errors are explicit — no silent fallbacks.
pub struct CliSigner {
    cli_path: String,
    address: String,
}

impl CliSigner {
    /// Create a `CliSigner`, fetching and caching the wallet address.
    ///
    /// Runs `remit address` to get the address from the keystore (no password needed).
    /// Fails loud if the CLI is not found or the keystore is missing.
    pub fn new() -> Result<Self, RemitError> {
        Self::with_path("remit")
    }

    /// Create a `CliSigner` with a custom CLI binary path.
    pub fn with_path(cli_path: &str) -> Result<Self, RemitError> {
        let output = Command::new(cli_path)
            .arg("address")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .map_err(|e| {
                remit_err(
                    codes::UNAUTHORIZED,
                    format!("CliSigner: failed to run `{cli_path} address`: {e}"),
                )
            })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(remit_err(
                codes::UNAUTHORIZED,
                format!(
                    "CliSigner: `{cli_path} address` failed: {}",
                    stderr.trim()
                ),
            ));
        }

        let addr = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !addr.starts_with("0x") || addr.len() != 42 {
            return Err(remit_err(
                codes::UNAUTHORIZED,
                format!("CliSigner: invalid address from CLI: {addr}"),
            ));
        }

        Ok(Self {
            cli_path: cli_path.to_string(),
            address: addr,
        })
    }

    /// Check all three conditions for CliSigner activation:
    /// 1. `remit` found on PATH
    /// 2. Keystore file exists at `~/.remit/keys/default.enc`
    /// 3. `REMIT_KEY_PASSWORD` env var is set (non-empty)
    pub fn is_available() -> bool {
        Self::is_available_with_path("remit")
    }

    /// Check availability with a custom CLI path.
    pub fn is_available_with_path(cli_path: &str) -> bool {
        // Check 1: CLI on PATH
        if which::which(cli_path).is_err() {
            return false;
        }

        // Check 2: Keystore exists
        let keystore_path = match dirs::home_dir() {
            Some(home) => home.join(".remit").join("keys").join("default.enc"),
            None => return false,
        };
        if !keystore_path.exists() {
            return false;
        }

        // Check 3: Password available
        match std::env::var("REMIT_KEY_PASSWORD") {
            Ok(val) if !val.is_empty() => true,
            _ => false,
        }
    }
}

impl Signer for CliSigner {
    fn sign(&self, digest: &[u8; 32]) -> Result<Vec<u8>, RemitError> {
        let hex_input = format!("0x{}", hex::encode(digest));

        let mut child = Command::new(&self.cli_path)
            .args(["sign", "--digest"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| {
                remit_err(
                    codes::UNAUTHORIZED,
                    format!("CliSigner: failed to spawn `{} sign`: {e}", self.cli_path),
                )
            })?;

        // Write to stdin and close it
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(hex_input.as_bytes()).map_err(|e| {
                remit_err(
                    codes::SERVER_ERROR,
                    format!("CliSigner: failed to write to stdin: {e}"),
                )
            })?;
            // stdin is dropped here, closing the pipe
        }

        let output = child.wait_with_output().map_err(|e| {
            remit_err(
                codes::SERVER_ERROR,
                format!("CliSigner: failed to read output: {e}"),
            )
        })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(remit_err(
                codes::UNAUTHORIZED,
                format!("CliSigner: signing failed: {}", stderr.trim()),
            ));
        }

        let sig_hex = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !sig_hex.starts_with("0x") || sig_hex.len() != 132 {
            return Err(remit_err(
                codes::SERVER_ERROR,
                format!("CliSigner: invalid signature from CLI: {sig_hex}"),
            ));
        }

        let sig_bytes = hex::decode(&sig_hex[2..]).map_err(|e| {
            remit_err(
                codes::SERVER_ERROR,
                format!("CliSigner: invalid signature hex: {e}"),
            )
        })?;

        if sig_bytes.len() != 65 {
            return Err(remit_err(
                codes::SERVER_ERROR,
                format!(
                    "CliSigner: expected 65-byte signature, got {} bytes",
                    sig_bytes.len()
                ),
            ));
        }

        Ok(sig_bytes)
    }

    fn address(&self) -> &str {
        &self.address
    }
}

impl std::fmt::Debug for CliSigner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CliSigner")
            .field("address", &self.address)
            .finish_non_exhaustive()
    }
}

/// Platform-specific install hint for the CLI.
pub fn cli_install_hint() -> &'static str {
    if cfg!(target_os = "macos") {
        "brew install remit-md/tap/remit"
    } else if cfg!(target_os = "windows") {
        "winget install remit-md.remit"
    } else {
        "curl -fsSL https://remit.md/install.sh | sh"
    }
}
