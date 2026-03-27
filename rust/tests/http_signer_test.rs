//! Tests for HttpSigner - uses a simple TcpListener mock server.

use remitmd::error::codes;
use remitmd::HttpSigner;
use remitmd::Signer;
use std::io::{Read, Write};
use std::net::TcpListener;

/// Spawn a mock HTTP server on a random port. Returns (url, join_handle).
///
/// `handler` receives (method, path, body) and returns (status_code, response_body_json).
fn mock_server(
    handler: impl Fn(&str, &str, &str) -> (u16, String) + Send + 'static,
) -> (String, std::thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock server");
    let port = listener.local_addr().unwrap().port();
    let url = format!("http://127.0.0.1:{port}");

    let handle = std::thread::spawn(move || {
        // Handle up to 10 requests (enough for all tests).
        for _ in 0..10 {
            let Ok((mut stream, _)) = listener.accept() else {
                break;
            };

            let mut buf = [0u8; 4096];
            let n = stream.read(&mut buf).unwrap_or(0);
            let raw = String::from_utf8_lossy(&buf[..n]).to_string();

            // Parse HTTP request line.
            let first_line = raw.lines().next().unwrap_or("");
            let parts: Vec<&str> = first_line.split_whitespace().collect();
            let method = parts.first().copied().unwrap_or("GET");
            let path = parts.get(1).copied().unwrap_or("/");

            // Extract body (after blank line).
            let body = raw.split("\r\n\r\n").nth(1).unwrap_or("").to_string();

            let (status, resp_body) = handler(method, path, &body);
            let status_text = match status {
                200 => "OK",
                401 => "Unauthorized",
                403 => "Forbidden",
                500 => "Internal Server Error",
                _ => "Error",
            };

            let response = format!(
                "HTTP/1.1 {status} {status_text}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{resp_body}",
                resp_body.len()
            );
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();
        }
    });

    (url, handle)
}

// ─── Test: Happy path ────────────────────────────────────────────────────────

#[test]
fn happy_path_create_and_sign() {
    // A fake 65-byte signature (all 0xAB, with v=27 at end).
    let fake_sig = format!("0x{}{:02x}", "ab".repeat(64), 27);

    let (url, _handle) = mock_server(move |method, path, _body| match (method, path) {
        ("GET", "/address") => (
            200,
            r#"{"address":"0x1234567890abcdef1234567890abcdef12345678"}"#.to_string(),
        ),
        ("POST", "/sign/digest") => (200, format!(r#"{{"signature":"{fake_sig}"}}"#)),
        _ => (404, r#"{"error":"not found"}"#.to_string()),
    });

    let signer = HttpSigner::new(&url, "test-token").expect("create HttpSigner");
    assert_eq!(
        signer.address(),
        "0x1234567890abcdef1234567890abcdef12345678"
    );

    let digest = [0xFFu8; 32];
    let sig = signer.sign(&digest).expect("sign digest");
    assert_eq!(sig.len(), 65, "signature must be 65 bytes");
    assert_eq!(sig[64], 27, "v byte should be 27");
}

// ─── Test: Server unreachable ────────────────────────────────────────────────

#[test]
fn server_unreachable() {
    // Use a port that nothing is listening on.
    let err = HttpSigner::new("http://127.0.0.1:1", "token").unwrap_err();
    assert_eq!(err.code, codes::NETWORK_ERROR);
    assert!(
        err.message.contains("cannot reach signer server"),
        "error message should mention unreachable: {}",
        err.message
    );
}

// ─── Test: 401 on GET /address ───────────────────────────────────────────────

#[test]
fn unauthorized_on_address() {
    let (url, _handle) =
        mock_server(|_method, _path, _body| (401, r#"{"error":"invalid token"}"#.to_string()));

    let err = HttpSigner::new(&url, "secret_bearer_12345").unwrap_err();
    assert_eq!(err.code, codes::UNAUTHORIZED);
    assert!(
        err.message.contains("unauthorized"),
        "error message should mention unauthorized: {}",
        err.message
    );
    // Actual bearer token value must never leak into error messages.
    assert!(
        !err.message.contains("secret_bearer_12345"),
        "bearer token value must not appear in error message"
    );
}

// ─── Test: 403 on POST /sign/digest ─────────────────────────────────────────

#[test]
fn forbidden_with_policy_reason() {
    let (url, _handle) = mock_server(|method, path, _body| match (method, path) {
        ("GET", "/address") => (
            200,
            r#"{"address":"0x1234567890abcdef1234567890abcdef12345678"}"#.to_string(),
        ),
        ("POST", "/sign/digest") => (
            403,
            r#"{"error":"forbidden","reason":"amount exceeds daily limit"}"#.to_string(),
        ),
        _ => (404, r#"{"error":"not found"}"#.to_string()),
    });

    let signer = HttpSigner::new(&url, "token").expect("create HttpSigner");
    let err = signer.sign(&[0u8; 32]).unwrap_err();
    assert_eq!(err.code, codes::UNAUTHORIZED);
    assert!(
        err.message.contains("policy denied"),
        "error message should mention policy: {}",
        err.message
    );
    assert!(
        err.message.contains("amount exceeds daily limit"),
        "error message should contain the policy reason: {}",
        err.message
    );
}

// ─── Test: 500 on POST /sign/digest ─────────────────────────────────────────

#[test]
fn server_error_on_sign() {
    let (url, _handle) = mock_server(|method, path, _body| match (method, path) {
        ("GET", "/address") => (
            200,
            r#"{"address":"0x1234567890abcdef1234567890abcdef12345678"}"#.to_string(),
        ),
        ("POST", "/sign/digest") => (
            500,
            r#"{"error":"internal error","reason":"HSM unavailable"}"#.to_string(),
        ),
        _ => (404, r#"{"error":"not found"}"#.to_string()),
    });

    let signer = HttpSigner::new(&url, "token").expect("create HttpSigner");
    let err = signer.sign(&[0u8; 32]).unwrap_err();
    assert_eq!(err.code, codes::SERVER_ERROR);
    assert!(
        err.message.contains("sign failed (500)"),
        "error message should contain status code: {}",
        err.message
    );
    assert!(
        err.message.contains("HSM unavailable"),
        "error message should contain reason: {}",
        err.message
    );
}

// ─── Test: Malformed response (invalid JSON) ────────────────────────────────

#[test]
fn malformed_address_response() {
    let (url, _handle) = mock_server(|_method, _path, _body| (200, "this is not json".to_string()));

    let err = HttpSigner::new(&url, "token").unwrap_err();
    assert_eq!(err.code, codes::SERVER_ERROR);
    assert!(
        err.message.contains("failed to parse"),
        "error message should mention parse failure: {}",
        err.message
    );
}

// ─── Test: Malformed signature response ─────────────────────────────────────

#[test]
fn malformed_signature_response() {
    let (url, _handle) = mock_server(|method, path, _body| match (method, path) {
        ("GET", "/address") => (
            200,
            r#"{"address":"0x1234567890abcdef1234567890abcdef12345678"}"#.to_string(),
        ),
        ("POST", "/sign/digest") => (200, r#"{"signature":"not-hex"}"#.to_string()),
        _ => (404, r#"{"error":"not found"}"#.to_string()),
    });

    let signer = HttpSigner::new(&url, "token").expect("create HttpSigner");
    let err = signer.sign(&[0u8; 32]).unwrap_err();
    assert_eq!(err.code, codes::SERVER_ERROR);
    assert!(
        err.message.contains("invalid hex"),
        "error message should mention hex error: {}",
        err.message
    );
}

// ─── Test: Wrong signature length ───────────────────────────────────────────

#[test]
fn wrong_signature_length() {
    // Only 32 bytes instead of 65.
    let short_sig = format!("0x{}", "ab".repeat(32));

    let (url, _handle) = mock_server(move |method, path, _body| match (method, path) {
        ("GET", "/address") => (
            200,
            r#"{"address":"0x1234567890abcdef1234567890abcdef12345678"}"#.to_string(),
        ),
        ("POST", "/sign/digest") => (200, format!(r#"{{"signature":"{short_sig}"}}"#)),
        _ => (404, r#"{"error":"not found"}"#.to_string()),
    });

    let signer = HttpSigner::new(&url, "token").expect("create HttpSigner");
    let err = signer.sign(&[0u8; 32]).unwrap_err();
    assert_eq!(err.code, codes::SERVER_ERROR);
    assert!(
        err.message.contains("expected 65-byte signature"),
        "error message should mention length: {}",
        err.message
    );
}

// ─── Test: 401 on POST /sign/digest ─────────────────────────────────────────

#[test]
fn unauthorized_on_sign() {
    let (url, _handle) = mock_server(|method, path, _body| match (method, path) {
        ("GET", "/address") => (
            200,
            r#"{"address":"0x1234567890abcdef1234567890abcdef12345678"}"#.to_string(),
        ),
        ("POST", "/sign/digest") => (401, r#"{"error":"token expired"}"#.to_string()),
        _ => (404, r#"{"error":"not found"}"#.to_string()),
    });

    let signer = HttpSigner::new(&url, "super_secret_bearer_value").expect("create HttpSigner");
    let err = signer.sign(&[0u8; 32]).unwrap_err();
    assert_eq!(err.code, codes::UNAUTHORIZED);
    assert!(
        err.message.contains("unauthorized"),
        "error message should mention unauthorized: {}",
        err.message
    );
    // Actual bearer token value must never leak into error messages.
    assert!(
        !err.message.contains("super_secret_bearer_value"),
        "bearer token value must not appear in error message: {}",
        err.message
    );
}

// ─── Test: Empty address ────────────────────────────────────────────────────

#[test]
fn empty_address_response() {
    let (url, _handle) =
        mock_server(|_method, _path, _body| (200, r#"{"address":""}"#.to_string()));

    let err = HttpSigner::new(&url, "token").unwrap_err();
    assert_eq!(err.code, codes::SERVER_ERROR);
    assert!(
        err.message.contains("empty address"),
        "error message should mention empty address: {}",
        err.message
    );
}
