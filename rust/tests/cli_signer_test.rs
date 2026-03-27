use remitmd::CliSigner;

#[test]
fn cli_signer_not_available_without_password() {
    // Ensure REMIT_KEY_PASSWORD is not set
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
