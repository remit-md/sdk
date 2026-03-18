//go:build acceptance

// Go SDK acceptance tests: payDirect + escrow lifecycle on live Base Sepolia.
//
// Run: go test -tags acceptance -timeout 300s -v -count=1
//
// Env vars (all optional):
//   ACCEPTANCE_API_URL  — default: https://remit.md
//   ACCEPTANCE_RPC_URL  — default: https://sepolia.base.org

package remitmd_test

import (
	"context"
	"crypto/ecdsa"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"math/big"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	remitmd "github.com/remit-md/sdk-go"
	"github.com/shopspring/decimal"
)

// ─── Config ──────────────────────────────────────────────────────────────────

var (
	acceptanceAPIURL = envOr("ACCEPTANCE_API_URL", "https://remit.md")
	acceptanceRPCURL = envOr("ACCEPTANCE_RPC_URL", "https://sepolia.base.org")
	usdcAddress      = common.HexToAddress("0x142aD61B8d2edD6b3807D9266866D97C35Ee0317")
	feeWalletAddr    = "0xd3f721BDF92a2bB5Dd8d2FE2AFC03aFE5629B420"
	baseSepoliaID    = big.NewInt(84532)
)

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// ─── Contract discovery (unauthenticated) ─────────────────────────────────────

type testContracts struct {
	Router string `json:"router"`
	Escrow string `json:"escrow"`
}

var cachedContracts *testContracts

func fetchContracts(t *testing.T) *testContracts {
	t.Helper()
	if cachedContracts != nil {
		return cachedContracts
	}
	resp, err := http.Get(acceptanceAPIURL + "/api/v0/contracts")
	if err != nil {
		t.Fatalf("GET /contracts failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("GET /contracts returned %d", resp.StatusCode)
	}
	var data testContracts
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		t.Fatalf("decode /contracts: %v", err)
	}
	if data.Router == "" {
		t.Fatal("/contracts returned empty router address")
	}
	cachedContracts = &data
	return cachedContracts
}

// ─── Wallet creation ──────────────────────────────────────────────────────────

type testWallet struct {
	*remitmd.Wallet
	key *ecdsa.PrivateKey
}

func createTestWallet(t *testing.T) *testWallet {
	t.Helper()
	contracts := fetchContracts(t)

	key, err := crypto.GenerateKey()
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	hexKey := "0x" + hex.EncodeToString(crypto.FromECDSA(key))

	wallet, err := remitmd.NewWallet(hexKey,
		remitmd.WithTestnet(),
		remitmd.WithBaseURL(acceptanceAPIURL),
		remitmd.WithRouterAddress(contracts.Router),
	)
	if err != nil {
		t.Fatalf("NewWallet: %v", err)
	}

	return &testWallet{Wallet: wallet, key: key}
}

// ─── On-chain balance via RPC ─────────────────────────────────────────────────

func getUsdcBalance(t *testing.T, address string) float64 {
	t.Helper()
	padded := strings.ToLower(strings.TrimPrefix(address, "0x"))
	for len(padded) < 64 {
		padded = "0" + padded
	}
	callData := "0x70a08231" + padded

	reqBody := fmt.Sprintf(
		`{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"%s","data":"%s"},"latest"]}`,
		usdcAddress.Hex(), callData,
	)

	resp, err := http.Post(acceptanceRPCURL, "application/json", strings.NewReader(reqBody))
	if err != nil {
		t.Fatalf("RPC balanceOf(%s): %v", address, err)
	}
	defer resp.Body.Close()

	var result struct {
		Result string `json:"result"`
		Error  *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("decode RPC response: %v", err)
	}
	if result.Error != nil {
		t.Fatalf("RPC error: %s", result.Error.Message)
	}

	bal, ok := new(big.Int).SetString(strings.TrimPrefix(result.Result, "0x"), 16)
	if !ok {
		t.Fatalf("parse balance hex: %s", result.Result)
	}

	f, _ := new(big.Float).Quo(
		new(big.Float).SetInt(bal),
		new(big.Float).SetFloat64(1e6),
	).Float64()
	return f
}

func getFeeBalance(t *testing.T) float64 {
	t.Helper()
	return getUsdcBalance(t, feeWalletAddr)
}

func waitForBalanceChange(t *testing.T, address string, before float64) float64 {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		current := getUsdcBalance(t, address)
		if math.Abs(current-before) > 0.0001 {
			return current
		}
		time.Sleep(2 * time.Second)
	}
	return getUsdcBalance(t, address)
}

func assertBalanceChange(t *testing.T, label string, before, after, expected float64) {
	t.Helper()
	actual := after - before
	tolerance := math.Abs(expected) * 0.001 // 10 bps
	if math.Abs(actual-expected) > tolerance {
		t.Fatalf("%s: expected delta %.6f, got %.6f (before=%.6f, after=%.6f)",
			label, expected, actual, before, after)
	}
}

// ─── Funding ──────────────────────────────────────────────────────────────────

func fundTestWallet(t *testing.T, w *testWallet, amount float64) {
	t.Helper()
	ctx := context.Background()
	_, err := w.Mint(ctx, amount)
	if err != nil {
		t.Fatalf("Mint(%v): %v", amount, err)
	}
	waitForBalanceChange(t, w.Address(), 0)
}

// ─── EIP-2612 Permit Signing ──────────────────────────────────────────────────

func signUSDCPermit(
	t *testing.T,
	key *ecdsa.PrivateKey,
	owner, spender common.Address,
	value, nonce, deadline *big.Int,
) *remitmd.PermitSignature {
	t.Helper()

	// ABI types (reused across calls)
	bytes32T, _ := abi.NewType("bytes32", "", nil)
	uint256T, _ := abi.NewType("uint256", "", nil)
	addressT, _ := abi.NewType("address", "", nil)

	// ── Domain separator ──
	domainTypeHash := crypto.Keccak256Hash(
		[]byte("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
	)
	nameHash := crypto.Keccak256Hash([]byte("USD Coin"))
	versionHash := crypto.Keccak256Hash([]byte("2"))

	domainPacked, err := abi.Arguments{
		{Type: bytes32T}, // typeHash
		{Type: bytes32T}, // name
		{Type: bytes32T}, // version
		{Type: uint256T}, // chainId
		{Type: addressT}, // verifyingContract
	}.Pack(domainTypeHash, nameHash, versionHash, baseSepoliaID, usdcAddress)
	if err != nil {
		t.Fatalf("pack domain: %v", err)
	}
	domainSep := crypto.Keccak256Hash(domainPacked)

	// ── Struct hash ──
	permitTypeHash := crypto.Keccak256Hash(
		[]byte("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
	)
	structPacked, err := abi.Arguments{
		{Type: bytes32T},  // typeHash
		{Type: addressT},  // owner
		{Type: addressT},  // spender
		{Type: uint256T},  // value
		{Type: uint256T},  // nonce
		{Type: uint256T},  // deadline
	}.Pack(permitTypeHash, owner, spender, value, nonce, deadline)
	if err != nil {
		t.Fatalf("pack permit struct: %v", err)
	}
	structHash := crypto.Keccak256Hash(structPacked)

	// ── EIP-712 digest ──
	digest := crypto.Keccak256Hash(
		append([]byte("\x19\x01"), append(domainSep[:], structHash[:]...)...),
	)

	// ── Sign ──
	sig, err := crypto.Sign(digest[:], key)
	if err != nil {
		t.Fatalf("sign permit: %v", err)
	}
	sig[64] += 27 // Ethereum v adjustment

	return &remitmd.PermitSignature{
		Value:    int(value.Int64()),
		Deadline: int(deadline.Int64()),
		V:        int(sig[64]),
		R:        "0x" + hex.EncodeToString(sig[:32]),
		S:        "0x" + hex.EncodeToString(sig[32:64]),
	}
}

// ─── Test: Direct Payment ─────────────────────────────────────────────────────

func TestPayDirectWithPermit(t *testing.T) {
	ctx := context.Background()

	agent := createTestWallet(t)
	provider := createTestWallet(t)
	fundTestWallet(t, agent, 100)

	amount := 1.0
	fee := 0.01
	providerReceives := amount - fee

	agentBefore := getUsdcBalance(t, agent.Address())
	providerBefore := getUsdcBalance(t, provider.Address())
	feeBefore := getFeeBalance(t)

	// Sign EIP-2612 permit for the Router contract
	contracts := fetchContracts(t)
	permit := signUSDCPermit(t, agent.key,
		crypto.PubkeyToAddress(agent.key.PublicKey),
		common.HexToAddress(contracts.Router),
		big.NewInt(2_000_000), // $2 USDC in base units
		big.NewInt(0),         // nonce 0 (fresh wallet)
		big.NewInt(time.Now().Unix()+3600),
	)

	tx, err := agent.Pay(ctx, provider.Address(), decimal.NewFromFloat(amount),
		remitmd.WithMemo("go-sdk-acceptance"),
		remitmd.WithPayPermit(permit),
	)
	if err != nil {
		t.Fatalf("Pay: %v", err)
	}
	if !strings.HasPrefix(tx.TxHash, "0x") {
		t.Fatalf("expected tx hash starting with 0x, got: %s", tx.TxHash)
	}

	agentAfter := waitForBalanceChange(t, agent.Address(), agentBefore)
	providerAfter := getUsdcBalance(t, provider.Address())
	feeAfter := getFeeBalance(t)

	assertBalanceChange(t, "agent", agentBefore, agentAfter, -amount)
	assertBalanceChange(t, "provider", providerBefore, providerAfter, providerReceives)
	assertBalanceChange(t, "fee wallet", feeBefore, feeAfter, fee)
}

// ─── Test: Escrow Lifecycle ───────────────────────────────────────────────────

func TestEscrowLifecycle(t *testing.T) {
	ctx := context.Background()

	agent := createTestWallet(t)
	provider := createTestWallet(t)
	fundTestWallet(t, agent, 100)

	amount := 5.0
	fee := amount * 0.01
	providerReceives := amount - fee

	agentBefore := getUsdcBalance(t, agent.Address())
	providerBefore := getUsdcBalance(t, provider.Address())
	feeBefore := getFeeBalance(t)

	// Sign EIP-2612 permit for the Escrow contract
	contracts := fetchContracts(t)
	permit := signUSDCPermit(t, agent.key,
		crypto.PubkeyToAddress(agent.key.PublicKey),
		common.HexToAddress(contracts.Escrow),
		big.NewInt(6_000_000), // $6 USDC in base units
		big.NewInt(0),         // nonce 0
		big.NewInt(time.Now().Unix()+3600),
	)

	// Create and fund escrow
	escrow, err := agent.CreateEscrow(ctx, provider.Address(), decimal.NewFromFloat(amount),
		remitmd.WithEscrowMemo("go-escrow-test"),
		remitmd.WithEscrowPermit(permit),
	)
	if err != nil {
		t.Fatalf("CreateEscrow: %v", err)
	}
	if escrow.InvoiceID == "" {
		t.Fatal("escrow should have an InvoiceID")
	}

	// Wait for on-chain lock
	waitForBalanceChange(t, agent.Address(), agentBefore)

	// Provider claims start
	_, err = provider.ClaimStart(ctx, escrow.InvoiceID)
	if err != nil {
		t.Fatalf("ClaimStart: %v", err)
	}
	time.Sleep(5 * time.Second)

	// Agent releases
	_, err = agent.ReleaseEscrow(ctx, escrow.InvoiceID)
	if err != nil {
		t.Fatalf("ReleaseEscrow: %v", err)
	}

	// Verify balances
	providerAfter := waitForBalanceChange(t, provider.Address(), providerBefore)
	feeAfter := getFeeBalance(t)
	agentAfter := getUsdcBalance(t, agent.Address())

	assertBalanceChange(t, "agent", agentBefore, agentAfter, -amount)
	assertBalanceChange(t, "provider", providerBefore, providerAfter, providerReceives)
	assertBalanceChange(t, "fee wallet", feeBefore, feeAfter, fee)
}
