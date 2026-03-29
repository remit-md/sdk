package remitmd

import (
	"crypto/ecdsa"
	"encoding/hex"
	"fmt"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)


// Signer signs EIP-712 typed data for authenticating API requests.
// Implement this interface to use hardware wallets, KMS, or other signing backends.
type Signer interface {
	// Sign returns an EIP-712 signature over the given digest (32 bytes).
	Sign(digest [32]byte) ([]byte, error)
	// SignHash signs a raw 32-byte hash and returns the 0x-prefixed hex signature (65 bytes: r+s+v).
	// Used by server-side permit/x402 flows where the server computes the EIP-712 hash.
	SignHash(hash []byte) (string, error)
	// Address returns the Ethereum address of the signing key.
	Address() common.Address
}

// PrivateKeySigner implements Signer using an in-memory ECDSA private key.
// For production agents, prefer a KMS-backed signer.
type PrivateKeySigner struct {
	key     *ecdsa.PrivateKey
	address common.Address
}

// NewPrivateKeySigner creates a Signer from a hex-encoded private key.
// The key may be 0x-prefixed or bare hex.
func NewPrivateKeySigner(hexKey string) (*PrivateKeySigner, error) {
	hexKey = strings.TrimPrefix(hexKey, "0x")
	keyBytes, err := hex.DecodeString(hexKey)
	if err != nil {
		return nil, remitErr(ErrCodeUnauthorized, "invalid private key: expected hex-encoded 32-byte value", map[string]any{
			"hint": "private keys are 64 hex characters, optionally prefixed with 0x",
		})
	}
	key, err := crypto.ToECDSA(keyBytes)
	if err != nil {
		return nil, remitErr(ErrCodeUnauthorized, fmt.Sprintf("invalid private key: %s", err), nil)
	}
	return &PrivateKeySigner{
		key:     key,
		address: crypto.PubkeyToAddress(key.PublicKey),
	}, nil
}

// Sign produces an Ethereum signature (65 bytes: r, s, v) over a 32-byte digest.
func (s *PrivateKeySigner) Sign(digest [32]byte) ([]byte, error) {
	sig, err := crypto.Sign(digest[:], s.key)
	if err != nil {
		return nil, fmt.Errorf("signing failed: %w", err)
	}
	// go-ethereum returns v as 0 or 1; Ethereum expects 27 or 28
	sig[64] += 27
	return sig, nil
}

// SignHash signs a raw 32-byte hash and returns a 0x-prefixed hex signature string.
func (s *PrivateKeySigner) SignHash(hash []byte) (string, error) {
	if len(hash) != 32 {
		return "", fmt.Errorf("SignHash: expected 32 bytes, got %d", len(hash))
	}
	var digest [32]byte
	copy(digest[:], hash)
	sig, err := s.Sign(digest)
	if err != nil {
		return "", err
	}
	return "0x" + hex.EncodeToString(sig), nil
}

// Address returns the Ethereum address for this signing key.
func (s *PrivateKeySigner) Address() common.Address {
	return s.address
}

// ─── EIP-712 domain and API request authentication ─────────────────────────────

var (
	domainType = abi.Arguments{
		{Type: mustType("bytes32")},  // typeHash
		{Type: mustType("bytes32")},  // name hash
		{Type: mustType("bytes32")},  // version hash
		{Type: mustType("uint256")},  // chainId
		{Type: mustType("address")},  // verifyingContract
	}
	apiRequestType = abi.Arguments{
		{Type: mustType("bytes32")},  // typeHash
		{Type: mustType("bytes32")},  // keccak256(method)
		{Type: mustType("bytes32")},  // keccak256(path)
		{Type: mustType("uint256")},  // timestamp
		{Type: mustType("bytes32")},  // nonce
	}

	domainTypeHash      = crypto.Keccak256Hash([]byte("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"))
	apiRequestTypeHash  = crypto.Keccak256Hash([]byte("APIRequest(string method,string path,uint256 timestamp,bytes32 nonce)"))
	nameHash            = crypto.Keccak256Hash([]byte("remit.md"))
	versionHash         = crypto.Keccak256Hash([]byte("0.1"))
)

// computeDomainSeparator returns the EIP-712 domain separator for a given chain and contract.
func computeDomainSeparator(chainID *big.Int, contract common.Address) [32]byte {
	packed, _ := domainType.Pack(domainTypeHash, nameHash, versionHash, chainID, contract)
	return crypto.Keccak256Hash(packed)
}

// computeRequestDigest computes the EIP-712 digest for authenticating an API request.
//
// This matches the server's auth middleware (auth.rs: compute_eip712_hash).
// Struct: APIRequest(string method, string path, uint256 timestamp, bytes32 nonce)
func computeRequestDigest(chainID *big.Int, contract common.Address, method, path string, timestamp uint64, nonce [32]byte) [32]byte {
	domain := computeDomainSeparator(chainID, contract)

	methodHash := crypto.Keccak256Hash([]byte(method))
	pathHash := crypto.Keccak256Hash([]byte(path))

	packed, _ := apiRequestType.Pack(
		apiRequestTypeHash,
		methodHash,
		pathHash,
		new(big.Int).SetUint64(timestamp),
		nonce,
	)
	structHash := crypto.Keccak256Hash(packed)

	return crypto.Keccak256Hash(
		append([]byte("\x19\x01"), append(domain[:], structHash[:]...)...),
	)
}

func mustType(t string) abi.Type {
	typ, err := abi.NewType(t, "", nil)
	if err != nil {
		panic(fmt.Sprintf("abi.NewType(%q): %v", t, err))
	}
	return typ
}
