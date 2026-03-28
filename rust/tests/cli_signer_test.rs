use remitmd::CliSigner;

#[test]
fn cli_signer_not_available_without_password() {
    // Ensure REMIT_SIGNER_KEY is not set
    std::env::remove_var("REMIT_SIGNER_KEY");
    std::env::remove_var("REMIT_KEY_PASSWORD");
    assert!(!CliSigner::is_available());
}

#[test]
fn cli_signer_not_available_with_bad_path() {
    assert!(!CliSigner::is_available_with_path(
        "nonexistent-binary-xyz-12345"
    ));
}

#[test]
fn cli_signer_new_fails_with_bad_path() {
    let result = CliSigner::with_path("nonexistent-binary-xyz-12345");
    assert!(result.is_err());
    let err = result.unwrap_err();
    assert_eq!(err.code, "UNAUTHORIZED");
}

#[test]
fn cli_signer_new_default_fails_without_binary() {
    // CliSigner::new() uses "remit" as the default path, which likely doesn't exist in CI
    let result = CliSigner::new();
    // Either succeeds (if remit is on PATH) or fails with UNAUTHORIZED
    if let Err(err) = result {
        assert_eq!(err.code, "UNAUTHORIZED");
    }
}

#[test]
fn cli_signer_debug_format() {
    // We can't create a real CliSigner without the binary, but we can test the error path
    let err = CliSigner::with_path("nonexistent-binary-xyz-12345").unwrap_err();
    let debug = format!("{:?}", err);
    assert!(debug.contains("UNAUTHORIZED"));
}

#[test]
fn cli_install_hint_returns_nonempty() {
    let hint = remitmd::cli_signer::cli_install_hint();
    assert!(!hint.is_empty());
    // Should contain a package manager command
    assert!(hint.contains("brew") || hint.contains("curl") || hint.contains("winget"));
}
