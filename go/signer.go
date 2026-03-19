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
	"github.com/shopspring/decimal"
)


// Signer signs EIP-712 typed data for authenticating API requests.
// Implement this interface to use hardware wallets, KMS, or other signing backends.
type Signer interface {
	// Sign returns an EIP-712 signature over the given digest (32 bytes).
	Sign(digest [32]byte) ([]byte, error)
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

// Address returns the Ethereum address for this signing key.
func (s *PrivateKeySigner) Address() common.Address {
	return s.address
}

// eip712Domain holds the parameters for the remit.md EIP-712 domain separator.
type eip712Domain struct {
	ChainID         *big.Int
	VerifyingContract common.Address
}

// paymentRequest is the EIP-712 struct type for direct payments.
type paymentRequest struct {
	Recipient common.Address
	Amount    *big.Int // USDC base units (6 decimals)
	Nonce     [32]byte
}

var (
	domainType = abi.Arguments{
		{Type: mustType("bytes32")},  // typeHash
		{Type: mustType("bytes32")},  // name hash
		{Type: mustType("bytes32")},  // version hash
		{Type: mustType("uint256")},  // chainId
		{Type: mustType("address")},  // verifyingContract
	}
	paymentType = abi.Arguments{
		{Type: mustType("bytes32")},  // typeHash
		{Type: mustType("address")},  // recipient
		{Type: mustType("uint256")},  // amount
		{Type: mustType("bytes32")},  // nonce
	}
	apiRequestType = abi.Arguments{
		{Type: mustType("bytes32")},  // typeHash
		{Type: mustType("bytes32")},  // keccak256(method)
		{Type: mustType("bytes32")},  // keccak256(path)
		{Type: mustType("uint256")},  // timestamp
		{Type: mustType("bytes32")},  // nonce
	}
	permitType = abi.Arguments{
		{Type: mustType("bytes32")},  // typeHash
		{Type: mustType("address")},  // owner
		{Type: mustType("address")},  // spender
		{Type: mustType("uint256")},  // value
		{Type: mustType("uint256")},  // nonce
		{Type: mustType("uint256")},  // deadline
	}

	domainTypeHash      = crypto.Keccak256Hash([]byte("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"))
	paymentTypeHash     = crypto.Keccak256Hash([]byte("Payment(address recipient,uint256 amount,bytes32 nonce)"))
	apiRequestTypeHash  = crypto.Keccak256Hash([]byte("APIRequest(string method,string path,uint256 timestamp,bytes32 nonce)"))
	permitTypeHash      = crypto.Keccak256Hash([]byte("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"))
	nameHash            = crypto.Keccak256Hash([]byte("remit.md"))
	versionHash         = crypto.Keccak256Hash([]byte("0.1"))

	// USDC EIP-712 domain uses name="USD Coin", version="2"
	usdcNameHash    = crypto.Keccak256Hash([]byte("USD Coin"))
	usdcVersionHash = crypto.Keccak256Hash([]byte("2"))
)

// computeDomainSeparator returns the EIP-712 domain separator for a given chain and contract.
func computeDomainSeparator(chainID *big.Int, contract common.Address) [32]byte {
	packed, _ := domainType.Pack(domainTypeHash, nameHash, versionHash, chainID, contract)
	return crypto.Keccak256Hash(packed)
}

// computePaymentDigest computes the EIP-712 digest for a payment request.
func computePaymentDigest(domain [32]byte, recipient common.Address, amount decimal.Decimal, nonce [32]byte) [32]byte {
	// Convert USDC amount to base units (6 decimals)
	baseUnits := amount.Mul(decimal.NewFromInt(1_000_000)).BigInt()

	packed, _ := paymentType.Pack(paymentTypeHash, recipient, baseUnits, nonce)
	structHash := crypto.Keccak256Hash(packed)

	// EIP-712 final digest: \x19\x01 || domainSeparator || structHash
	digest := crypto.Keccak256Hash(
		append([]byte("\x19\x01"), append(domain[:], structHash[:]...)...),
	)
	return digest
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

// computeUsdcDomainSeparator returns the EIP-712 domain separator for USDC (name="USD Coin", version="2").
func computeUsdcDomainSeparator(chainID *big.Int, usdcAddress common.Address) [32]byte {
	packed, _ := domainType.Pack(domainTypeHash, usdcNameHash, usdcVersionHash, chainID, usdcAddress)
	return crypto.Keccak256Hash(packed)
}

// computePermitDigest computes the EIP-712 digest for an EIP-2612 Permit message.
// Domain: name="USD Coin", version="2", chainId, verifyingContract=USDC address.
// Type: Permit(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline).
func computePermitDigest(chainID *big.Int, usdcAddress, owner, spender common.Address, value, nonce, deadline *big.Int) [32]byte {
	domain := computeUsdcDomainSeparator(chainID, usdcAddress)

	packed, _ := permitType.Pack(permitTypeHash, owner, spender, value, nonce, deadline)
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
