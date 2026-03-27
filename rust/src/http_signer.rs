//! HTTP signer adapter for the remit local signer server.
//!
//! Delegates digest signing to an HTTP server on localhost (typically
//! `http://127.0.0.1:7402`). The signer server holds the encrypted key;
//! this adapter only needs a bearer token and URL.
//!
//! # Usage
//!
//! ```rust,ignore
//! use remitmd::HttpSigner;
//! use remitmd::Wallet;
//!
//! let signer = HttpSigner::new("http://127.0.0.1:7402", "rmit_sk_...")?;
//! let wallet = Wallet::with_signer(signer).testnet().build()?;
//! ```

use crate::error::{codes, remit_err, RemitError};
use crate::signer::Signer;

/// Response from `GET /address`.
#[derive(serde::Deserialize)]
struct AddressResponse {
    address: String,
}

/// Response from `POST /sign/digest`.
#[derive(serde::Deserialize)]
struct SignatureResponse {
    signature: String,
}

/// Error response body from the signer server.
#[derive(serde::Deserialize)]
struct ErrorResponse {
    #[serde(default)]
    error: String,
    #[serde(default)]
    reason: String,
}

/// Signer backed by a local HTTP signing server.
///
/// - Bearer token is held privately, never serialized or logged.
/// - Address is cached at construction time (`GET /address`).
/// - `sign()` POSTs a hex digest to `/sign/digest` and returns 65 bytes.
/// - All errors are explicit -- no silent fallbacks, no default values.
pub struct HttpSigner {
    url: String,
    token: String,
    address: String,
}

impl HttpSigner {
    /// Create an `HttpSigner`, fetching and caching the wallet address.
    ///
    /// Calls `GET /address` with bearer-token auth. Fails loud if the server
    /// is unreachable, returns an auth error, or sends a malformed response.
    ///
    /// # Arguments
    /// - `url`   -- signer server URL (e.g. `"http://127.0.0.1:7402"`)
    /// - `token` -- bearer token for authentication
    pub fn new(url: &str, token: &str) -> Result<Self, RemitError> {
        let url = url.trim_end_matches('/').to_string();

        let resp = ureq::get(&format!("{url}/address"))
            .set("Authorization", &format!("Bearer {token}"))
            .call()
            .map_err(|e| map_address_error(e, &url))?;

        let data: AddressResponse = resp.into_json().map_err(|e| {
            remit_err(
                codes::SERVER_ERROR,
                format!("HttpSigner: failed to parse /address response: {e}"),
            )
        })?;

        if data.address.is_empty() {
            return Err(remit_err(
                codes::SERVER_ERROR,
                "HttpSigner: GET /address returned empty address",
            ));
        }

        Ok(Self {
            url,
            token: token.to_string(),
            address: data.address,
        })
    }
}

impl Signer for HttpSigner {
    fn sign(&self, digest: &[u8; 32]) -> Result<Vec<u8>, RemitError> {
        let hex_digest = format!("0x{}", hex::encode(digest));
        let body = serde_json::json!({ "digest": hex_digest });

        let resp = ureq::post(&format!("{}/sign/digest", self.url))
            .set("Content-Type", "application/json")
            .set("Authorization", &format!("Bearer {}", self.token))
            .send_json(body)
            .map_err(map_sign_error)?;

        let data: SignatureResponse = resp.into_json().map_err(|e| {
            remit_err(
                codes::SERVER_ERROR,
                format!("HttpSigner: failed to parse /sign/digest response: {e}"),
            )
        })?;

        if data.signature.is_empty() {
            return Err(remit_err(
                codes::SERVER_ERROR,
                "HttpSigner: server returned empty signature",
            ));
        }

        let sig_hex = data.signature.trim_start_matches("0x");
        let sig_bytes = hex::decode(sig_hex).map_err(|e| {
            remit_err(
                codes::SERVER_ERROR,
                format!("HttpSigner: invalid hex in signature: {e}"),
            )
        })?;

        if sig_bytes.len() != 65 {
            return Err(remit_err(
                codes::SERVER_ERROR,
                format!(
                    "HttpSigner: expected 65-byte signature, got {} bytes",
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

impl std::fmt::Debug for HttpSigner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HttpSigner")
            .field("url", &self.url)
            .field("address", &self.address)
            .finish_non_exhaustive()
    }
}

// ─── Error mapping helpers (consume ureq::Error by value) ────────────────────

/// Read the JSON error body from a ureq Response, consuming it.
fn read_error_body(resp: ureq::Response) -> Option<ErrorResponse> {
    resp.into_json::<ErrorResponse>().ok()
}

/// Map `GET /address` errors to `RemitError`.
fn map_address_error(err: ureq::Error, url: &str) -> RemitError {
    match err {
        ureq::Error::Transport(_) => remit_err(
            codes::NETWORK_ERROR,
            format!("HttpSigner: cannot reach signer server at {url}"),
        ),
        ureq::Error::Status(401, _) => remit_err(
            codes::UNAUTHORIZED,
            "HttpSigner: unauthorized -- check your REMIT_SIGNER_TOKEN",
        ),
        ureq::Error::Status(code, resp) => {
            let detail = read_error_body(resp)
                .and_then(|r| {
                    if !r.error.is_empty() {
                        Some(r.error)
                    } else {
                        None
                    }
                })
                .unwrap_or_else(|| "unknown error".to_string());
            remit_err(
                codes::SERVER_ERROR,
                format!("HttpSigner: GET /address failed ({code}): {detail}"),
            )
        }
    }
}

/// Map `POST /sign/digest` errors to `RemitError`.
fn map_sign_error(err: ureq::Error) -> RemitError {
    match err {
        ureq::Error::Transport(_) => remit_err(
            codes::NETWORK_ERROR,
            "HttpSigner: cannot reach signer server",
        ),
        ureq::Error::Status(401, _) => remit_err(
            codes::UNAUTHORIZED,
            "HttpSigner: unauthorized -- check your REMIT_SIGNER_TOKEN",
        ),
        ureq::Error::Status(403, resp) => {
            let reason = read_error_body(resp)
                .and_then(|r| {
                    if r.reason.is_empty() {
                        None
                    } else {
                        Some(r.reason)
                    }
                })
                .unwrap_or_else(|| "unknown reason".to_string());
            remit_err(
                codes::UNAUTHORIZED,
                format!("HttpSigner: policy denied -- {reason}"),
            )
        }
        ureq::Error::Status(code, resp) => {
            let detail = read_error_body(resp)
                .and_then(|r| {
                    if !r.reason.is_empty() {
                        Some(r.reason)
                    } else if !r.error.is_empty() {
                        Some(r.error)
                    } else {
                        None
                    }
                })
                .unwrap_or_else(|| "unknown error".to_string());
            remit_err(
                codes::SERVER_ERROR,
                format!("HttpSigner: sign failed ({code}): {detail}"),
            )
        }
    }
}
