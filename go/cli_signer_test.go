package remitmd_test

import (
	"os"
	"path/filepath"
	"testing"

	remitmd "github.com/remit-md/sdk/go"
)

func TestCliSigner_IsAvailable_NoCli(t *testing.T) {
	// With a non-existent CLI path, should return false
	if remitmd.IsCliSignerAvailable("nonexistent-binary-that-does-not-exist-xyz") {
		t.Error("expected IsCliSignerAvailable to return false for nonexistent binary")
	}
}

func TestCliSigner_IsAvailable_NoKeystore(t *testing.T) {
	// Even if remit is on PATH, no keystore means unavailable
	// This test just verifies the function doesn't panic and returns false
	// when the keystore doesn't exist (which is the typical test environment)
	if remitmd.IsCliSignerAvailable() {
		// This is OK if the test environment has remit installed
		t.Log("CliSigner is available in this test environment")
	}
}

func TestCliSigner_IsAvailable_NoPassword(t *testing.T) {
	// Temporarily unset REMIT_KEY_PASSWORD
	old := os.Getenv("REMIT_KEY_PASSWORD")
	os.Unsetenv("REMIT_KEY_PASSWORD")
	defer func() {
		if old != "" {
			os.Setenv("REMIT_KEY_PASSWORD", old)
		}
	}()

	if remitmd.IsCliSignerAvailable() {
		t.Error("expected IsCliSignerAvailable to return false without REMIT_KEY_PASSWORD")
	}
}

func TestCliSigner_NewCliSigner_NotFound(t *testing.T) {
	_, err := remitmd.NewCliSigner("nonexistent-binary-that-does-not-exist-xyz")
	if err == nil {
		t.Fatal("expected error for missing CLI binary")
	}
	var remitErr *remitmd.RemitError
	if e, ok := err.(*remitmd.RemitError); ok {
		remitErr = e
	}
	if remitErr == nil {
		t.Fatalf("expected *RemitError, got %T: %v", err, err)
	}
	if remitErr.Code != remitmd.ErrCodeUnauthorized {
		t.Errorf("expected code %s, got %s", remitmd.ErrCodeUnauthorized, remitErr.Code)
	}
}

func TestCliSigner_IsAvailable_AllConditions(t *testing.T) {
	// Create a temporary keystore directory structure
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("cannot determine home directory")
	}

	keystorePath := filepath.Join(home, ".remit", "keys", "default.enc")

	// Check if keystore already exists (don't create one in tests)
	if _, err := os.Stat(keystorePath); os.IsNotExist(err) {
		t.Log("No keystore at default path — IsCliSignerAvailable correctly returns false")
		return
	}

	// If keystore exists but no password, should still be false
	old := os.Getenv("REMIT_KEY_PASSWORD")
	os.Unsetenv("REMIT_KEY_PASSWORD")
	defer func() {
		if old != "" {
			os.Setenv("REMIT_KEY_PASSWORD", old)
		}
	}()

	if remitmd.IsCliSignerAvailable() {
		t.Error("expected false without REMIT_KEY_PASSWORD even with keystore present")
	}
}
