package remitmd_test

import (
	"testing"

	"github.com/remit-md/sdk/go"
)

func TestNewPrivateKeySigner_Valid(t *testing.T) {
	// A valid 32-byte hex key (this is a well-known test key, not a real wallet)
	key := "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
	signer, err := remitmd.NewPrivateKeySigner(key)
	if err != nil {
		t.Fatalf("NewPrivateKeySigner failed: %v", err)
	}
	addr := signer.Address()
	if addr.Hex() == "" {
		t.Error("Address() returned empty")
	}
}

func TestNewPrivateKeySigner_WithPrefix(t *testing.T) {
	key := "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
	signer, err := remitmd.NewPrivateKeySigner(key)
	if err != nil {
		t.Fatalf("NewPrivateKeySigner failed with 0x prefix: %v", err)
	}
	if signer.Address().Hex() == "" {
		t.Error("Address() returned empty")
	}
}

func TestNewPrivateKeySigner_InvalidHex(t *testing.T) {
	_, err := remitmd.NewPrivateKeySigner("not-hex-at-all")
	if err == nil {
		t.Fatal("expected error for invalid hex key")
	}
}

func TestNewPrivateKeySigner_EmptyKey(t *testing.T) {
	_, err := remitmd.NewPrivateKeySigner("")
	if err == nil {
		t.Fatal("expected error for empty key")
	}
}

func TestPrivateKeySigner_Sign(t *testing.T) {
	key := "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
	signer, err := remitmd.NewPrivateKeySigner(key)
	if err != nil {
		t.Fatalf("NewPrivateKeySigner failed: %v", err)
	}

	digest := [32]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
		17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32}

	sig, err := signer.Sign(digest)
	if err != nil {
		t.Fatalf("Sign failed: %v", err)
	}
	if len(sig) != 65 {
		t.Errorf("expected 65-byte signature, got %d bytes", len(sig))
	}
	// v should be 27 or 28 (Ethereum convention)
	if sig[64] != 27 && sig[64] != 28 {
		t.Errorf("expected v=27 or v=28, got %d", sig[64])
	}
}
