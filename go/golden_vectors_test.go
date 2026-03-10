package remitmd

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

// ─── JSON shape ───────────────────────────────────────────────────────────────

type gvDomain struct {
	Name              string `json:"name"`
	Version           string `json:"version"`
	ChainID           uint64 `json:"chain_id"`
	VerifyingContract string `json:"verifying_contract"`
}

type gvMessage struct {
	Method    string      `json:"method"`
	Path      string      `json:"path"`
	Timestamp json.Number `json:"timestamp"` // json.Number avoids float64 precision loss for u64::MAX
	Nonce     string      `json:"nonce"`
}

type gvVector struct {
	Description             string    `json:"description"`
	Domain                  gvDomain  `json:"domain"`
	Message                 gvMessage `json:"message"`
	ExpectedDomainSeparator string    `json:"expected_domain_separator"`
	ExpectedStructHash      string    `json:"expected_struct_hash"`
	ExpectedHash            string    `json:"expected_hash"`
	ExpectedSignature       string    `json:"expected_signature"`
}

type gvFile struct {
	Vectors []gvVector `json:"vectors"`
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

func gvLoadVectors(t *testing.T) []gvVector {
	t.Helper()
	data, err := os.ReadFile("../test-vectors/eip712.json")
	if err != nil {
		t.Fatalf("read test-vectors/eip712.json: %v\n"+
			"Run `cargo run --bin gen_vectors > test-vectors/eip712.json` in remit-server.", err)
	}
	var f gvFile
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatalf("parse test vectors: %v", err)
	}
	if len(f.Vectors) == 0 {
		t.Fatal("vectors array must not be empty")
	}
	return f.Vectors
}

func gvParseNonce(s string) ([32]byte, error) {
	s = strings.TrimPrefix(s, "0x")
	b, err := hex.DecodeString(s)
	if err != nil {
		return [32]byte{}, err
	}
	if len(b) != 32 {
		return [32]byte{}, fmt.Errorf("nonce: expected 32 bytes, got %d", len(b))
	}
	var arr [32]byte
	copy(arr[:], b)
	return arr, nil
}

func gvParseTimestamp(n json.Number) (uint64, error) {
	return strconv.ParseUint(n.String(), 10, 64)
}

// ─── Tests ────────────────────────────────────────────────────────────────────

// TestGoldenVectorsHash verifies that computeRequestDigest produces the same
// EIP-712 hash as the server for every canonical test vector.
//
// If any assertion fails, the Go SDK's EIP-712 implementation diverges from the
// server and authentication WILL fail in production.
func TestGoldenVectorsHash(t *testing.T) {
	vectors := gvLoadVectors(t)

	for _, v := range vectors {
		v := v
		t.Run(v.Description, func(t *testing.T) {
			nonce, err := gvParseNonce(v.Message.Nonce)
			if err != nil {
				t.Fatalf("parse nonce: %v", err)
			}
			ts, err := gvParseTimestamp(v.Message.Timestamp)
			if err != nil {
				t.Fatalf("parse timestamp: %v", err)
			}

			chainID := new(big.Int).SetUint64(v.Domain.ChainID)
			contract := common.HexToAddress(v.Domain.VerifyingContract)

			gotHash := computeRequestDigest(chainID, contract, v.Message.Method, v.Message.Path, ts, nonce)
			gotHex := "0x" + hex.EncodeToString(gotHash[:])

			if gotHex != v.ExpectedHash {
				t.Errorf("EIP-712 hash mismatch for %q:\n  got:      %s\n  expected: %s",
					v.Description, gotHex, v.ExpectedHash)
			}
		})
	}
}

// TestGoldenVectorsSignature verifies that PrivateKeySigner produces the same
// ECDSA signature as the server for every canonical test vector.
func TestGoldenVectorsSignature(t *testing.T) {
	// Anvil test wallet #0 — same key used by gen_vectors in remit-server.
	const testPrivKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
	signer, err := NewPrivateKeySigner(testPrivKey)
	if err != nil {
		t.Fatalf("create signer: %v", err)
	}

	vectors := gvLoadVectors(t)

	for _, v := range vectors {
		v := v
		t.Run(v.Description, func(t *testing.T) {
			nonce, err := gvParseNonce(v.Message.Nonce)
			if err != nil {
				t.Fatalf("parse nonce: %v", err)
			}
			ts, err := gvParseTimestamp(v.Message.Timestamp)
			if err != nil {
				t.Fatalf("parse timestamp: %v", err)
			}

			chainID := new(big.Int).SetUint64(v.Domain.ChainID)
			contract := common.HexToAddress(v.Domain.VerifyingContract)

			digest := computeRequestDigest(chainID, contract, v.Message.Method, v.Message.Path, ts, nonce)
			sig, err := signer.Sign(digest)
			if err != nil {
				t.Fatalf("sign: %v", err)
			}

			gotSig := "0x" + hex.EncodeToString(sig)
			if gotSig != v.ExpectedSignature {
				t.Errorf("signature mismatch for %q:\n  got:      %s\n  expected: %s",
					v.Description, gotSig, v.ExpectedSignature)
			}
		})
	}
}
