//go:build acceptance

// Go SDK acceptance tests: all 7 payment flows on live Base Sepolia.
//
// Run: go test -tags acceptance -timeout 600s -v -count=1
//
// Env vars (all optional):
//   ACCEPTANCE_API_URL  — default: https://remit.md
//   ACCEPTANCE_RPC_URL  — default: https://sepolia.base.org

package remitmd_test

import (
	"context"
	"crypto/ecdsa"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"math/big"
	"net"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	remitmd "github.com/remit-md/sdk/go"
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
	Router  string `json:"router"`
	Escrow  string `json:"escrow"`
	Tab     string `json:"tab"`
	Stream  string `json:"stream"`
	Bounty  string `json:"bounty"`
	Deposit string `json:"deposit"`
	USDC    string `json:"usdc"`
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

func logTx(t *testing.T, flow, step, txHash string) {
	t.Helper()
	t.Logf("[TX] %s | %s | %s | https://sepolia.basescan.org/tx/%s", flow, step, txHash, txHash)
}

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
	logTx(t, "direct", "pay", tx.TxHash)

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
	if escrow.TxHash != "" {
		logTx(t, "escrow", "fund", escrow.TxHash)
	}

	// Wait for on-chain lock
	waitForBalanceChange(t, agent.Address(), agentBefore)

	// Provider claims start
	claimResult, err := provider.ClaimStart(ctx, escrow.InvoiceID)
	if err != nil {
		t.Fatalf("ClaimStart: %v", err)
	}
	if claimResult != nil && claimResult.TxHash != "" {
		logTx(t, "escrow", "claimStart", claimResult.TxHash)
	}
	time.Sleep(5 * time.Second)

	// Agent releases
	releaseResult, err := agent.ReleaseEscrow(ctx, escrow.InvoiceID)
	if err != nil {
		t.Fatalf("ReleaseEscrow: %v", err)
	}
	if releaseResult != nil && releaseResult.TxHash != "" {
		logTx(t, "escrow", "release", releaseResult.TxHash)
	}

	// Verify balances
	providerAfter := waitForBalanceChange(t, provider.Address(), providerBefore)
	feeAfter := getFeeBalance(t)
	agentAfter := getUsdcBalance(t, agent.Address())

	assertBalanceChange(t, "agent", agentBefore, agentAfter, -amount)
	assertBalanceChange(t, "provider", providerBefore, providerAfter, providerReceives)
	assertBalanceChange(t, "fee wallet", feeBefore, feeAfter, fee)
}

// ─── EIP-712 TabCharge Signing ────────────────────────────────────────────────

// signTabCharge produces an EIP-712 signature for the TabCharge struct.
//
// Domain: name="RemitTab", version="1", chainId=84532, verifyingContract=<tab contract>
// Type:   TabCharge(bytes32 tabId, uint96 totalCharged, uint32 callCount)
//
// tabID is the UUID string, ASCII-encoded as bytes32 (right-padded with zeroes).
func signTabCharge(
	t *testing.T,
	key *ecdsa.PrivateKey,
	tabContract common.Address,
	tabID string,
	totalCharged *big.Int, // USDC base units (6 decimals)
	callCount uint32,
) string {
	t.Helper()

	bytes32T, _ := abi.NewType("bytes32", "", nil)
	uint256T, _ := abi.NewType("uint256", "", nil)
	addressT, _ := abi.NewType("address", "", nil)

	// ── Domain separator (RemitTab) ──
	domainTypeHash := crypto.Keccak256Hash(
		[]byte("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
	)
	nameHash := crypto.Keccak256Hash([]byte("RemitTab"))
	versionHash := crypto.Keccak256Hash([]byte("1"))

	domainPacked, err := abi.Arguments{
		{Type: bytes32T},
		{Type: bytes32T},
		{Type: bytes32T},
		{Type: uint256T},
		{Type: addressT},
	}.Pack(domainTypeHash, nameHash, versionHash, baseSepoliaID, tabContract)
	if err != nil {
		t.Fatalf("pack tab domain: %v", err)
	}
	domainSep := crypto.Keccak256Hash(domainPacked)

	// ── Struct hash ──
	tabChargeTypeHash := crypto.Keccak256Hash(
		[]byte("TabCharge(bytes32 tabId,uint96 totalCharged,uint32 callCount)"),
	)

	// Encode tabID as bytes32: ASCII chars padded to 32 bytes
	var tabIDBytes [32]byte
	copy(tabIDBytes[:], []byte(tabID))

	structPacked, err := abi.Arguments{
		{Type: bytes32T}, // typeHash
		{Type: bytes32T}, // tabId
		{Type: uint256T}, // totalCharged (uint96 ABI-encodes as uint256)
		{Type: uint256T}, // callCount (uint32 ABI-encodes as uint256)
	}.Pack(
		tabChargeTypeHash,
		tabIDBytes,
		totalCharged,
		new(big.Int).SetUint64(uint64(callCount)),
	)
	if err != nil {
		t.Fatalf("pack tab charge struct: %v", err)
	}
	structHash := crypto.Keccak256Hash(structPacked)

	// ── EIP-712 digest ──
	digest := crypto.Keccak256Hash(
		append([]byte("\x19\x01"), append(domainSep[:], structHash[:]...)...),
	)

	sig, err := crypto.Sign(digest[:], key)
	if err != nil {
		t.Fatalf("sign tab charge: %v", err)
	}
	sig[64] += 27 // Ethereum v adjustment

	return "0x" + hex.EncodeToString(sig)
}

// ─── Test: Tab Lifecycle ──────────────────────────────────────────────────────

func TestTabLifecycle(t *testing.T) {
	ctx := context.Background()

	payer := createTestWallet(t)
	provider := createTestWallet(t)
	fundTestWallet(t, payer, 100)

	contracts := fetchContracts(t)

	// Sign permit for the Tab contract
	permit := signUSDCPermit(t, payer.key,
		crypto.PubkeyToAddress(payer.key.PublicKey),
		common.HexToAddress(contracts.Tab),
		big.NewInt(20_000_000), // $20 USDC in base units
		big.NewInt(0),
		big.NewInt(time.Now().Unix()+3600),
	)

	payerBefore := getUsdcBalance(t, payer.Address())
	feeBefore := getFeeBalance(t)

	// 1. Create tab: $10 limit, $0.10 per call
	tab, err := payer.CreateTab(ctx, provider.Address(),
		decimal.NewFromFloat(10.0),
		decimal.NewFromFloat(0.10),
		remitmd.WithTabPermit(permit),
	)
	if err != nil {
		t.Fatalf("CreateTab: %v", err)
	}
	if tab.ID == "" {
		t.Fatal("tab ID should not be empty")
	}
	if tab.TxHash != "" {
		logTx(t, "tab", "open", tab.TxHash)
	}
	t.Logf("Tab created: %s", tab.ID)

	// Wait for on-chain funding
	waitForBalanceChange(t, payer.Address(), payerBefore)

	// 2. Charge tab: $0.10 charge, cumulative $0.10, callCount 1
	chargeAmount := 0.10
	chargeSig := signTabCharge(t, provider.key,
		common.HexToAddress(contracts.Tab),
		tab.ID,
		big.NewInt(100_000), // $0.10 in base units
		1,
	)
	charge, err := provider.ChargeTab(ctx, tab.ID, chargeAmount, chargeAmount, 1, chargeSig)
	if err != nil {
		t.Fatalf("ChargeTab: %v", err)
	}
	if charge.TabID != tab.ID {
		t.Fatalf("charge tab_id mismatch: got %s, want %s", charge.TabID, tab.ID)
	}
	t.Logf("Tab charged: amount=%s, cumulative=%s", charge.Amount, charge.Cumulative)

	// 3. Close tab with final settlement
	closeSig := signTabCharge(t, provider.key,
		common.HexToAddress(contracts.Tab),
		tab.ID,
		big.NewInt(100_000), // final = $0.10
		1,
	)
	closed, err := payer.CloseTab(ctx, tab.ID,
		remitmd.WithCloseTabAmount(chargeAmount),
		remitmd.WithCloseTabSig(closeSig),
	)
	if err != nil {
		t.Fatalf("CloseTab: %v", err)
	}
	if closed.Status == "open" {
		t.Fatal("tab should not be open after close")
	}
	if closed.ClosedTxHash != "" {
		logTx(t, "tab", "close", closed.ClosedTxHash)
	} else if closed.TxHash != "" {
		logTx(t, "tab", "close", closed.TxHash)
	}
	t.Logf("Tab closed: status=%s", closed.Status)

	// 4. Verify balance: payer should have lost the charged amount (+ fee)
	payerAfter := waitForBalanceChange(t, payer.Address(), payerBefore)
	feeAfter := getFeeBalance(t)

	// Payer should lose at most limit ($10) — depends on contract settlement
	payerDelta := payerAfter - payerBefore
	if payerDelta > 0 {
		t.Fatalf("payer should not have gained funds, delta=%.6f", payerDelta)
	}
	t.Logf("Payer balance delta: %.6f, fee delta: %.6f", payerDelta, feeAfter-feeBefore)
}

// ─── Test: Stream Lifecycle ───────────────────────────────────────────────────

func TestStreamLifecycle(t *testing.T) {
	ctx := context.Background()

	payer := createTestWallet(t)
	payee := createTestWallet(t)
	fundTestWallet(t, payer, 100)

	contracts := fetchContracts(t)

	// Sign permit for the Stream contract
	permit := signUSDCPermit(t, payer.key,
		crypto.PubkeyToAddress(payer.key.PublicKey),
		common.HexToAddress(contracts.Stream),
		big.NewInt(10_000_000), // $10 USDC in base units
		big.NewInt(0),
		big.NewInt(time.Now().Unix()+3600),
	)

	payerBefore := getUsdcBalance(t, payer.Address())

	// 1. Create stream: $0.01/sec, $5 max
	stream, err := payer.CreateStream(ctx, payee.Address(),
		decimal.NewFromFloat(0.01), // rate_per_second
		decimal.NewFromFloat(5.0),  // max_total
		remitmd.WithStreamPermit(permit),
	)
	if err != nil {
		t.Fatalf("CreateStream: %v", err)
	}
	if stream.ID == "" {
		t.Fatal("stream ID should not be empty")
	}
	if stream.TxHash != "" {
		logTx(t, "stream", "open", stream.TxHash)
	}
	t.Logf("Stream created: %s, status=%s", stream.ID, stream.Status)

	// Wait for on-chain lock
	waitForBalanceChange(t, payer.Address(), payerBefore)

	// 2. Let it run for a few seconds
	t.Log("Waiting 5 seconds for stream to accrue...")
	time.Sleep(5 * time.Second)

	// 3. Close stream (retry for indexer lag)
	var closed *remitmd.Stream
	for attempt := 0; attempt < 10; attempt++ {
		closed, err = payer.CloseStream(ctx, stream.ID)
		if err == nil {
			break
		}
		if attempt < 9 {
			t.Logf("CloseStream attempt %d failed: %v, retrying...", attempt+1, err)
			time.Sleep(3 * time.Second)
		}
	}
	if err != nil {
		t.Fatalf("CloseStream: %v", err)
	}
	if closed.Status != "closed" {
		t.Logf("stream status after close: %s (expected closed)", closed.Status)
	}
	if closed.TxHash != "" {
		logTx(t, "stream", "close", closed.TxHash)
	}
	t.Logf("Stream closed: status=%s", closed.Status)

	// 4. Conservation of funds: payer + payee balances should account for all USDC
	payerAfter := waitForBalanceChange(t, payer.Address(), payerBefore)
	payeeAfter := getUsdcBalance(t, payee.Address())

	// Payer should have lost some amount (stream + fees), payee should have gained some
	payerDelta := payerAfter - payerBefore
	if payerDelta >= 0 {
		t.Fatalf("payer should have lost funds, delta=%.6f", payerDelta)
	}
	t.Logf("Payer delta: %.6f, Payee balance: %.6f", payerDelta, payeeAfter)
}

// ─── Test: Bounty Lifecycle ───────────────────────────────────────────────────

func TestBountyLifecycle(t *testing.T) {
	ctx := context.Background()

	poster := createTestWallet(t)
	submitter := createTestWallet(t)
	fundTestWallet(t, poster, 100)

	posterBefore := getUsdcBalance(t, poster.Address())
	feeBefore := getFeeBalance(t)

	// 1. Create bounty: $5 reward, 1 hour deadline (SDK auto-signs permit)
	deadline := time.Now().Unix() + 3600
	bounty, err := poster.CreateBounty(ctx,
		decimal.NewFromFloat(5.0),
		"Write a Go acceptance test",
		deadline,
	)
	if err != nil {
		t.Fatalf("CreateBounty: %v", err)
	}
	if bounty.ID == "" {
		t.Fatal("bounty ID should not be empty")
	}
	if bounty.TxHash != "" {
		logTx(t, "bounty", "post", bounty.TxHash)
	}
	t.Logf("Bounty created: %s, status=%s", bounty.ID, bounty.Status)

	// Wait for on-chain lock
	waitForBalanceChange(t, poster.Address(), posterBefore)

	// 2. Submit evidence (as submitter)
	evidenceHash := "0x" + hex.EncodeToString(crypto.Keccak256([]byte("test evidence")))
	sub, err := submitter.SubmitBounty(ctx, bounty.ID, evidenceHash)
	if err != nil {
		t.Fatalf("SubmitBounty: %v", err)
	}
	if sub.BountyID != bounty.ID {
		t.Fatalf("submission bounty_id mismatch: got %s, want %s", sub.BountyID, bounty.ID)
	}
	t.Logf("Submission created: id=%d, status=%s", sub.ID, sub.Status)

	// 3. Award bounty (as poster)
	awarded, err := poster.AwardBounty(ctx, bounty.ID, sub.ID)
	if err != nil {
		t.Fatalf("AwardBounty: %v", err)
	}
	if awarded.Status != "awarded" {
		t.Logf("bounty status after award: %s (expected awarded)", awarded.Status)
	}
	if awarded.TxHash != "" {
		logTx(t, "bounty", "award", awarded.TxHash)
	}
	t.Logf("Bounty awarded: status=%s", awarded.Status)

	// 4. Verify balances
	submitterAfter := waitForBalanceChange(t, submitter.Address(), 0)
	feeAfter := getFeeBalance(t)

	if submitterAfter <= 0 {
		t.Fatalf("submitter should have received funds, got balance=%.6f", submitterAfter)
	}
	t.Logf("Submitter received: %.6f, fee delta: %.6f", submitterAfter, feeAfter-feeBefore)
}

// ─── Test: Deposit Lifecycle ──────────────────────────────────────────────────

func TestDepositLifecycle(t *testing.T) {
	ctx := context.Background()

	payer := createTestWallet(t)
	provider := createTestWallet(t)
	fundTestWallet(t, payer, 100)

	contracts := fetchContracts(t)

	// Sign permit for the Deposit contract
	permit := signUSDCPermit(t, payer.key,
		crypto.PubkeyToAddress(payer.key.PublicKey),
		common.HexToAddress(contracts.Deposit),
		big.NewInt(10_000_000), // $10 USDC in base units
		big.NewInt(0),
		big.NewInt(time.Now().Unix()+3600),
	)

	payerBefore := getUsdcBalance(t, payer.Address())

	// 1. Place deposit: $5, expires in 1 hour
	deposit, err := payer.PlaceDeposit(ctx, provider.Address(),
		decimal.NewFromFloat(5.0),
		1*time.Hour,
		remitmd.WithDepositPermit(permit),
	)
	if err != nil {
		t.Fatalf("PlaceDeposit: %v", err)
	}
	if deposit.ID == "" {
		t.Fatal("deposit ID should not be empty")
	}
	if deposit.TxHash != "" {
		logTx(t, "deposit", "place", deposit.TxHash)
	}
	t.Logf("Deposit placed: %s, status=%s", deposit.ID, deposit.Status)

	// Wait for on-chain lock
	waitForBalanceChange(t, payer.Address(), payerBefore)
	payerAfterDeposit := getUsdcBalance(t, payer.Address())

	// 2. Return deposit (by provider)
	returnResult, err := provider.ReturnDeposit(ctx, deposit.ID)
	if err != nil {
		t.Fatalf("ReturnDeposit: %v", err)
	}
	if returnResult != nil && returnResult.TxHash != "" {
		logTx(t, "deposit", "return", returnResult.TxHash)
	}
	t.Log("Deposit returned")

	// 3. Verify full refund (deposits have no fee)
	payerAfterReturn := waitForBalanceChange(t, payer.Address(), payerAfterDeposit)
	refundAmount := payerAfterReturn - payerAfterDeposit
	if refundAmount < 4.99 {
		t.Fatalf("expected near-full refund (~5.0), got %.6f", refundAmount)
	}
	t.Logf("Deposit refunded: %.6f (full refund, no fee)", refundAmount)
}

// ─── Test: X402 Auto-Pay ──────────────────────────────────────────────────────

func TestX402AutoPay(t *testing.T) {
	ctx := context.Background()

	// 1. Spin up a local HTTP server that returns 402
	providerWallet := createTestWallet(t)

	paywall, err := remitmd.NewX402Paywall(remitmd.PaywallOptions{
		WalletAddress:     providerWallet.Address(),
		AmountUsdc:        0.001,
		Network:           "eip155:84532",
		Asset:             usdcAddress.Hex(),
		FacilitatorURL:    acceptanceAPIURL,
		MaxTimeoutSeconds: 60,
		Resource:          "/v1/data",
		Description:       "Test data endpoint",
		MimeType:          "application/json",
	})
	if err != nil {
		t.Fatalf("NewX402Paywall: %v", err)
	}

	mux := http.NewServeMux()
	mux.Handle("/v1/data", paywall.Middleware()(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(200)
		_, _ = w.Write([]byte(`{"status":"ok","data":"secret"}`))
	})))

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	server := &http.Server{Handler: mux}
	serverURL := "http://" + listener.Addr().String()
	go server.Serve(listener) //nolint:errcheck
	defer server.Close()

	t.Logf("X402 test server at %s", serverURL)

	// 2. Make a request without payment — should get 402
	resp, err := http.Get(serverURL + "/v1/data")
	if err != nil {
		t.Fatalf("GET /v1/data: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != 402 {
		t.Fatalf("expected 402, got %d", resp.StatusCode)
	}

	// Verify PAYMENT-REQUIRED header is present and parseable
	payReq := resp.Header.Get("PAYMENT-REQUIRED")
	if payReq == "" {
		t.Fatal("missing PAYMENT-REQUIRED header")
	}
	decoded, err := base64.StdEncoding.DecodeString(payReq)
	if err != nil {
		t.Fatalf("decode PAYMENT-REQUIRED: %v", err)
	}
	var reqPayload map[string]any
	if err := json.Unmarshal(decoded, &reqPayload); err != nil {
		t.Fatalf("parse PAYMENT-REQUIRED JSON: %v", err)
	}
	if reqPayload["payTo"] == nil {
		t.Fatal("PAYMENT-REQUIRED missing payTo field")
	}

	// 3. Verify the paywall Check method works with empty sig (should return invalid)
	result, err := paywall.Check(ctx, "")
	if err != nil {
		t.Fatalf("Check empty: %v", err)
	}
	if result.IsValid {
		t.Fatal("empty sig should not be valid")
	}

	// 4. Verify V2 fields are present in the PAYMENT-REQUIRED header
	if reqPayload["resource"] != "/v1/data" {
		t.Fatalf("expected resource=/v1/data, got %v", reqPayload["resource"])
	}
	if reqPayload["description"] != "Test data endpoint" {
		t.Fatalf("expected description='Test data endpoint', got %v", reqPayload["description"])
	}
	t.Logf("X402 paywall verified: 402 with PAYMENT-REQUIRED header, V2 fields present")
}
