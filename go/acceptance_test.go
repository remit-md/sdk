//go:build acceptance

// Go SDK acceptance tests: 9 payment flows with 2 shared wallets on live Base Sepolia.
//
// Run: go test -tags acceptance -timeout 600s -v -count=1
//
// Env vars (all optional):
//   ACCEPTANCE_API_URL  - default: https://testnet.remit.md
//   ACCEPTANCE_RPC_URL  - default: https://sepolia.base.org

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
	acceptanceAPIURL = envOr("ACCEPTANCE_API_URL", "https://testnet.remit.md")
	acceptanceRPCURL = envOr("ACCEPTANCE_RPC_URL", "https://sepolia.base.org")
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
	ChainID uint64 `json:"chain_id"`
}

var cachedContracts *testContracts

func fetchContracts(t *testing.T) *testContracts {
	t.Helper()
	if cachedContracts != nil {
		return cachedContracts
	}
	resp, err := http.Get(acceptanceAPIURL + "/api/v1/contracts")
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
	key    *ecdsa.PrivateKey
	hexKey string
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

	t.Logf("[ACCEPTANCE] wallet: %s (chain=84532)", wallet.Address())
	return &testWallet{Wallet: wallet, key: key, hexKey: hexKey}
}

// ─── On-chain balance via RPC ─────────────────────────────────────────────────

func getUsdcBalance(t *testing.T, usdcAddr, address string) float64 {
	t.Helper()
	padded := strings.ToLower(strings.TrimPrefix(address, "0x"))
	for len(padded) < 64 {
		padded = "0" + padded
	}
	callData := "0x70a08231" + padded

	reqBody := fmt.Sprintf(
		`{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"%s","data":"%s"},"latest"]}`,
		usdcAddr, callData,
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

func waitForBalanceChange(t *testing.T, usdcAddr, address string, before float64) float64 {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		current := getUsdcBalance(t, usdcAddr, address)
		if math.Abs(current-before) > 0.0001 {
			return current
		}
		time.Sleep(2 * time.Second)
	}
	return getUsdcBalance(t, usdcAddr, address)
}

func assertBalanceChange(t *testing.T, label string, before, after, expected float64) {
	t.Helper()
	actual := after - before
	tolerance := math.Max(math.Abs(expected)*0.02, 0.01) // 2% or 1 cent
	if math.Abs(actual-expected) > tolerance {
		t.Fatalf("%s: expected delta %.6f, got %.6f (before=%.6f, after=%.6f)",
			label, expected, actual, before, after)
	}
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

func logTx(t *testing.T, flow, step, txHash string) {
	t.Helper()
	t.Logf("[ACCEPTANCE] %s | %s | tx=%s | https://sepolia.basescan.org/tx/%s", flow, step, txHash, txHash)
}

func fundTestWallet(t *testing.T, w *testWallet, amount float64) {
	t.Helper()
	t.Logf("[ACCEPTANCE] mint: %.1f USDC -> %s", amount, w.Address())
	ctx := context.Background()
	contracts := fetchContracts(t)
	_, err := w.Mint(ctx, amount)
	if err != nil {
		t.Fatalf("Mint(%v): %v", amount, err)
	}
	waitForBalanceChange(t, contracts.USDC, w.Address(), 0)
}

// ─── EIP-712 TabCharge Signing ────────────────────────────────────────────────

func signTabCharge(
	t *testing.T,
	key *ecdsa.PrivateKey,
	tabContract common.Address,
	chainID *big.Int,
	tabID string,
	totalCharged *big.Int,
	callCount uint32,
) string {
	t.Helper()

	bytes32T, _ := abi.NewType("bytes32", "", nil)
	uint256T, _ := abi.NewType("uint256", "", nil)
	addressT, _ := abi.NewType("address", "", nil)

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
	}.Pack(domainTypeHash, nameHash, versionHash, chainID, tabContract)
	if err != nil {
		t.Fatalf("pack tab domain: %v", err)
	}
	domainSep := crypto.Keccak256Hash(domainPacked)

	tabChargeTypeHash := crypto.Keccak256Hash(
		[]byte("TabCharge(bytes32 tabId,uint96 totalCharged,uint32 callCount)"),
	)

	var tabIDBytes [32]byte
	copy(tabIDBytes[:], []byte(tabID))

	structPacked, err := abi.Arguments{
		{Type: bytes32T},
		{Type: bytes32T},
		{Type: uint256T},
		{Type: uint256T},
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

	digest := crypto.Keccak256Hash(
		append([]byte("\x19\x01"), append(domainSep[:], structHash[:]...)...),
	)

	sig, err := crypto.Sign(digest[:], key)
	if err != nil {
		t.Fatalf("sign tab charge: %v", err)
	}
	sig[64] += 27

	return "0x" + hex.EncodeToString(sig)
}

// ─── Shared wallets ──────────────────────────────────────────────────────────

var (
	sharedAgent    *testWallet
	sharedProvider *testWallet
)

func TestMain(m *testing.M) {
	// Cannot use t.Helper() here — TestMain gets *testing.M, not *testing.T.
	// Use fmt for setup logging.
	fmt.Println("[ACCEPTANCE] setting up shared wallets...")

	contracts := fetchContractsForMain()
	if contracts == nil {
		fmt.Println("[ACCEPTANCE] FATAL: could not fetch contracts")
		os.Exit(1)
	}

	agent := createWalletForMain(contracts)
	provider := createWalletForMain(contracts)

	// Fund agent with 100 USDC
	fmt.Printf("[ACCEPTANCE] minting 100 USDC -> %s\n", agent.Address())
	ctx := context.Background()
	_, err := agent.Mint(ctx, 100)
	if err != nil {
		fmt.Printf("[ACCEPTANCE] FATAL: Mint failed: %v\n", err)
		os.Exit(1)
	}
	// Wait for balance
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		bal := getUsdcBalanceRaw(contracts.USDC, agent.Address())
		if bal > 0.001 {
			break
		}
		time.Sleep(2 * time.Second)
	}
	fmt.Printf("[ACCEPTANCE] agent funded: %s\n", agent.Address())

	sharedAgent = agent
	sharedProvider = provider

	os.Exit(m.Run())
}

// fetchContractsForMain is a TestMain-safe version (no *testing.T).
func fetchContractsForMain() *testContracts {
	resp, err := http.Get(acceptanceAPIURL + "/api/v1/contracts")
	if err != nil {
		fmt.Printf("[ACCEPTANCE] GET /contracts failed: %v\n", err)
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		fmt.Printf("[ACCEPTANCE] GET /contracts returned %d\n", resp.StatusCode)
		return nil
	}
	var data testContracts
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		fmt.Printf("[ACCEPTANCE] decode /contracts: %v\n", err)
		return nil
	}
	cachedContracts = &data
	return cachedContracts
}

func createWalletForMain(contracts *testContracts) *testWallet {
	key, err := crypto.GenerateKey()
	if err != nil {
		fmt.Printf("[ACCEPTANCE] FATAL: generate key: %v\n", err)
		os.Exit(1)
	}
	hexKey := "0x" + hex.EncodeToString(crypto.FromECDSA(key))

	wallet, err := remitmd.NewWallet(hexKey,
		remitmd.WithTestnet(),
		remitmd.WithBaseURL(acceptanceAPIURL),
		remitmd.WithRouterAddress(contracts.Router),
	)
	if err != nil {
		fmt.Printf("[ACCEPTANCE] FATAL: NewWallet: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("[ACCEPTANCE] wallet: %s (chain=84532)\n", wallet.Address())
	return &testWallet{Wallet: wallet, key: key, hexKey: hexKey}
}

// getUsdcBalanceRaw is a TestMain-safe version (no *testing.T).
func getUsdcBalanceRaw(usdcAddr, address string) float64 {
	padded := strings.ToLower(strings.TrimPrefix(address, "0x"))
	for len(padded) < 64 {
		padded = "0" + padded
	}
	callData := "0x70a08231" + padded
	reqBody := fmt.Sprintf(
		`{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"%s","data":"%s"},"latest"]}`,
		usdcAddr, callData,
	)
	resp, err := http.Post(acceptanceRPCURL, "application/json", strings.NewReader(reqBody))
	if err != nil {
		return 0
	}
	defer resp.Body.Close()
	var result struct {
		Result string `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return 0
	}
	bal, ok := new(big.Int).SetString(strings.TrimPrefix(result.Result, "0x"), 16)
	if !ok {
		return 0
	}
	f, _ := new(big.Float).Quo(
		new(big.Float).SetInt(bal),
		new(big.Float).SetFloat64(1e6),
	).Float64()
	return f
}

// ─── Flow 1: Direct ──────────────────────────────────────────────────────────

func TestDirect(t *testing.T) {
	ctx := context.Background()
	agent := sharedAgent
	provider := sharedProvider
	contracts := fetchContracts(t)
	amount := 1.0

	agentBefore := getUsdcBalance(t, contracts.USDC, agent.Address())
	providerBefore := getUsdcBalance(t, contracts.USDC, provider.Address())

	permit, err := agent.SignPermit(ctx, "direct", amount)
	if err != nil {
		t.Fatalf("SignPermit: %v", err)
	}

	tx, err := agent.Pay(ctx, provider.Address(), decimal.NewFromFloat(amount),
		remitmd.WithMemo("acceptance-direct"),
		remitmd.WithPayPermit(permit),
	)
	if err != nil {
		t.Fatalf("Pay: %v", err)
	}
	if !strings.HasPrefix(tx.TxHash, "0x") {
		t.Fatalf("expected tx hash starting with 0x, got: %s", tx.TxHash)
	}
	logTx(t, "direct", fmt.Sprintf("%.1f USDC %s->%s", amount, agent.Address(), provider.Address()), tx.TxHash)

	agentAfter := waitForBalanceChange(t, contracts.USDC, agent.Address(), agentBefore)
	providerAfter := getUsdcBalance(t, contracts.USDC, provider.Address())

	assertBalanceChange(t, "agent", agentBefore, agentAfter, -amount)
	assertBalanceChange(t, "provider", providerBefore, providerAfter, amount*0.99)
}

// ─── Flow 2: Escrow ──────────────────────────────────────────────────────────

func TestEscrow(t *testing.T) {
	ctx := context.Background()
	agent := sharedAgent
	provider := sharedProvider
	contracts := fetchContracts(t)
	amount := 2.0

	agentBefore := getUsdcBalance(t, contracts.USDC, agent.Address())
	providerBefore := getUsdcBalance(t, contracts.USDC, provider.Address())

	permit, err := agent.SignPermit(ctx, "escrow", amount)
	if err != nil {
		t.Fatalf("SignPermit: %v", err)
	}

	escrow, err := agent.CreateEscrow(ctx, provider.Address(), decimal.NewFromFloat(amount),
		remitmd.WithEscrowMemo("acceptance-escrow"),
		remitmd.WithEscrowPermit(permit),
	)
	if err != nil {
		t.Fatalf("CreateEscrow: %v", err)
	}
	if escrow.InvoiceID == "" {
		t.Fatal("escrow should have an InvoiceID")
	}
	if escrow.TxHash != "" {
		logTx(t, "escrow", fmt.Sprintf("fund %.1f USDC", amount), escrow.TxHash)
	}

	waitForBalanceChange(t, contracts.USDC, agent.Address(), agentBefore)

	claimResult, err := provider.ClaimStart(ctx, escrow.InvoiceID)
	if err != nil {
		t.Fatalf("ClaimStart: %v", err)
	}
	if claimResult != nil && claimResult.TxHash != "" {
		logTx(t, "escrow", "claimStart", claimResult.TxHash)
	}
	time.Sleep(5 * time.Second)

	releaseResult, err := agent.ReleaseEscrow(ctx, escrow.InvoiceID)
	if err != nil {
		t.Fatalf("ReleaseEscrow: %v", err)
	}
	if releaseResult != nil && releaseResult.TxHash != "" {
		logTx(t, "escrow", "release", releaseResult.TxHash)
	}

	providerAfter := waitForBalanceChange(t, contracts.USDC, provider.Address(), providerBefore)
	agentAfter := getUsdcBalance(t, contracts.USDC, agent.Address())

	assertBalanceChange(t, "agent", agentBefore, agentAfter, -amount)
	assertBalanceChange(t, "provider", providerBefore, providerAfter, amount*0.99)
}

// ─── Flow 3: Tab ─────────────────────────────────────────────────────────────

func TestTab(t *testing.T) {
	ctx := context.Background()
	agent := sharedAgent
	provider := sharedProvider
	contracts := fetchContracts(t)
	chainID := new(big.Int).SetUint64(contracts.ChainID)

	limit := 5.0
	chargeAmount := 1.0
	chargeUnits := int64(chargeAmount * 1_000_000)

	agentBefore := getUsdcBalance(t, contracts.USDC, agent.Address())
	providerBefore := getUsdcBalance(t, contracts.USDC, provider.Address())

	permit, err := agent.SignPermit(ctx, "tab", limit)
	if err != nil {
		t.Fatalf("SignPermit: %v", err)
	}

	tab, err := agent.CreateTab(ctx, provider.Address(),
		decimal.NewFromFloat(limit),
		decimal.NewFromFloat(0.1),
		remitmd.WithTabPermit(permit),
	)
	if err != nil {
		t.Fatalf("CreateTab: %v", err)
	}
	if tab.ID == "" {
		t.Fatal("tab ID should not be empty")
	}
	if tab.TxHash != "" {
		logTx(t, "tab", fmt.Sprintf("open limit=%.1f", limit), tab.TxHash)
	}

	waitForBalanceChange(t, contracts.USDC, agent.Address(), agentBefore)

	// Charge tab
	callCount := uint32(1)
	chargeSig := signTabCharge(t, provider.key,
		common.HexToAddress(contracts.Tab),
		chainID,
		tab.ID,
		big.NewInt(chargeUnits),
		callCount,
	)
	charge, err := provider.ChargeTab(ctx, tab.ID, chargeAmount, chargeAmount, int(callCount), chargeSig)
	if err != nil {
		t.Fatalf("ChargeTab: %v", err)
	}
	if charge.TabID != tab.ID {
		t.Fatalf("charge tab_id mismatch: got %s, want %s", charge.TabID, tab.ID)
	}

	// Close tab
	closeSig := signTabCharge(t, provider.key,
		common.HexToAddress(contracts.Tab),
		chainID,
		tab.ID,
		big.NewInt(chargeUnits),
		callCount,
	)
	closed, err := agent.CloseTab(ctx, tab.ID,
		remitmd.WithCloseTabAmount(chargeAmount),
		remitmd.WithCloseTabSig(closeSig),
	)
	if err != nil {
		t.Fatalf("CloseTab: %v", err)
	}
	if closed.TxHash == "" || !strings.HasPrefix(closed.TxHash, "0x") {
		t.Fatalf("expected tx hash starting with 0x, got: %s", closed.TxHash)
	}
	logTx(t, "tab", "close", closed.TxHash)

	providerAfter := waitForBalanceChange(t, contracts.USDC, provider.Address(), providerBefore)
	agentAfter := getUsdcBalance(t, contracts.USDC, agent.Address())

	assertBalanceChange(t, "agent", agentBefore, agentAfter, -chargeAmount)
	assertBalanceChange(t, "provider", providerBefore, providerAfter, chargeAmount*0.99)
}

// ─── Flow 4: Stream ──────────────────────────────────────────────────────────

func TestStream(t *testing.T) {
	ctx := context.Background()
	agent := sharedAgent
	provider := sharedProvider
	contracts := fetchContracts(t)

	rate := 0.1 // $0.10/s
	maxTotal := 2.0

	agentBefore := getUsdcBalance(t, contracts.USDC, agent.Address())
	providerBefore := getUsdcBalance(t, contracts.USDC, provider.Address())

	permit, err := agent.SignPermit(ctx, "stream", maxTotal)
	if err != nil {
		t.Fatalf("SignPermit: %v", err)
	}

	stream, err := agent.CreateStream(ctx, provider.Address(),
		decimal.NewFromFloat(rate),
		decimal.NewFromFloat(maxTotal),
		remitmd.WithStreamPermit(permit),
	)
	if err != nil {
		t.Fatalf("CreateStream: %v", err)
	}
	if stream.ID == "" {
		t.Fatal("stream ID should not be empty")
	}
	if stream.TxHash != "" {
		logTx(t, "stream", fmt.Sprintf("open rate=%.1f/s max=%.1f", rate, maxTotal), stream.TxHash)
	}

	waitForBalanceChange(t, contracts.USDC, agent.Address(), agentBefore)
	time.Sleep(5 * time.Second)

	// Close stream (retry for Ponder indexer lag)
	var closedTx *remitmd.Transaction
	for attempt := 0; attempt < 20; attempt++ {
		closedTx, err = agent.CloseStream(ctx, stream.ID)
		if err == nil {
			break
		}
		if attempt < 19 {
			t.Logf("[ACCEPTANCE] stream | CloseStream retry %d: %v", attempt+1, err)
			time.Sleep(5 * time.Second)
		}
	}
	if err != nil {
		t.Fatalf("CloseStream: %v", err)
	}
	if closedTx.TxHash != "" {
		logTx(t, "stream", "close", closedTx.TxHash)
	}

	providerAfter := waitForBalanceChange(t, contracts.USDC, provider.Address(), providerBefore)
	agentAfter := getUsdcBalance(t, contracts.USDC, agent.Address())

	agentLoss := agentBefore - agentAfter
	if agentLoss < 0.05 {
		t.Fatalf("agent should lose money, loss=%.6f", agentLoss)
	}
	if agentLoss > maxTotal+0.01 {
		t.Fatalf("agent loss %.6f exceeds max_total %.1f", agentLoss, maxTotal)
	}

	providerGain := providerAfter - providerBefore
	if providerGain < 0.04 {
		t.Fatalf("provider should gain, gain=%.6f", providerGain)
	}
}

// ─── Flow 5: Bounty ──────────────────────────────────────────────────────────

func TestBounty(t *testing.T) {
	ctx := context.Background()
	agent := sharedAgent
	provider := sharedProvider
	contracts := fetchContracts(t)
	amount := 2.0
	deadlineTs := time.Now().Unix() + 3600

	agentBefore := getUsdcBalance(t, contracts.USDC, agent.Address())
	providerBefore := getUsdcBalance(t, contracts.USDC, provider.Address())

	permit, err := agent.SignPermit(ctx, "bounty", amount)
	if err != nil {
		t.Fatalf("SignPermit: %v", err)
	}

	bounty, err := agent.CreateBounty(ctx,
		decimal.NewFromFloat(amount),
		"acceptance-bounty",
		deadlineTs,
		remitmd.WithBountyPermit(permit),
	)
	if err != nil {
		t.Fatalf("CreateBounty: %v", err)
	}
	if bounty.ID == "" {
		t.Fatal("bounty ID should not be empty")
	}
	if bounty.TxHash != "" {
		logTx(t, "bounty", fmt.Sprintf("post %.1f USDC", amount), bounty.TxHash)
	}

	waitForBalanceChange(t, contracts.USDC, agent.Address(), agentBefore)

	// Submit evidence
	evidenceHash := "0x" + hex.EncodeToString(crypto.Keccak256([]byte("test evidence")))
	sub, err := provider.SubmitBounty(ctx, bounty.ID, evidenceHash)
	if err != nil {
		t.Fatalf("SubmitBounty: %v", err)
	}
	t.Logf("[ACCEPTANCE] bounty | submit | id=%s, sub=%d", bounty.ID, sub.ID)

	// Retry award (Ponder indexer lag)
	var awarded *remitmd.Transaction
	for attempt := 0; attempt < 15; attempt++ {
		time.Sleep(3 * time.Second)
		awarded, err = agent.AwardBounty(ctx, bounty.ID, sub.ID)
		if err == nil {
			break
		}
		if attempt < 14 {
			t.Logf("[ACCEPTANCE] bounty award retry %d: %v", attempt+1, err)
		} else {
			t.Fatalf("AwardBounty failed after 15 retries: %v", err)
		}
	}
	if awarded != nil && awarded.TxHash != "" {
		logTx(t, "bounty", "award", awarded.TxHash)
	}

	providerAfter := waitForBalanceChange(t, contracts.USDC, provider.Address(), providerBefore)
	agentAfter := getUsdcBalance(t, contracts.USDC, agent.Address())

	assertBalanceChange(t, "agent", agentBefore, agentAfter, -amount)
	assertBalanceChange(t, "provider", providerBefore, providerAfter, amount*0.99)
}

// ─── Flow 6: Deposit ─────────────────────────────────────────────────────────

func TestDeposit(t *testing.T) {
	ctx := context.Background()
	agent := sharedAgent
	provider := sharedProvider
	contracts := fetchContracts(t)
	amount := 2.0

	agentBefore := getUsdcBalance(t, contracts.USDC, agent.Address())

	permit, err := agent.SignPermit(ctx, "deposit", amount)
	if err != nil {
		t.Fatalf("SignPermit: %v", err)
	}

	deposit, err := agent.PlaceDeposit(ctx, provider.Address(),
		decimal.NewFromFloat(amount),
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
		logTx(t, "deposit", fmt.Sprintf("place %.1f USDC", amount), deposit.TxHash)
	}

	agentMid := waitForBalanceChange(t, contracts.USDC, agent.Address(), agentBefore)
	assertBalanceChange(t, "agent locked", agentBefore, agentMid, -amount)

	returned, err := provider.ReturnDeposit(ctx, deposit.ID)
	if err != nil {
		t.Fatalf("ReturnDeposit: %v", err)
	}
	if returned != nil && returned.TxHash != "" {
		logTx(t, "deposit", "return", returned.TxHash)
	}

	agentAfter := waitForBalanceChange(t, contracts.USDC, agent.Address(), agentMid)
	assertBalanceChange(t, "agent refund", agentBefore, agentAfter, 0)
}

// ─── Flow 7: x402 Prepare ────────────────────────────────────────────────────

func TestX402Prepare(t *testing.T) {
	ctx := context.Background()
	agent := sharedAgent
	contracts := fetchContracts(t)

	paymentRequired := map[string]any{
		"scheme":            "exact",
		"network":           "eip155:84532",
		"amount":            "100000", // $0.10 USDC
		"asset":             contracts.USDC,
		"payTo":             contracts.Router,
		"maxTimeoutSeconds": 60,
	}
	encoded := base64.StdEncoding.EncodeToString(mustJSON(t, paymentRequired))

	// POST /api/v1/x402/prepare
	permit, err := agent.SignPermit(ctx, "direct", 0.10)
	if err != nil {
		t.Fatalf("SignPermit for x402: %v", err)
	}
	_ = permit // permit not needed for /x402/prepare, but validates server-side signing works

	body := map[string]any{
		"payment_required": encoded,
		"payer":            agent.Address(),
	}
	bodyBytes := mustJSON(t, body)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		acceptanceAPIURL+"/api/v1/x402/prepare",
		strings.NewReader(string(bodyBytes)),
	)
	if err != nil {
		t.Fatalf("build x402/prepare request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST /x402/prepare: %v", err)
	}
	defer resp.Body.Close()

	var data map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		t.Fatalf("decode x402/prepare response: %v", err)
	}

	hashVal, ok := data["hash"]
	if !ok {
		t.Fatalf("x402/prepare missing hash: %v", data)
	}
	hashStr, ok := hashVal.(string)
	if !ok || !strings.HasPrefix(hashStr, "0x") {
		t.Fatalf("x402/prepare hash not 0x-prefixed: %v", hashVal)
	}
	if len(hashStr) != 66 {
		t.Fatalf("x402/prepare hash wrong length: got %d, want 66", len(hashStr))
	}
	if _, ok := data["from"]; !ok {
		t.Fatal("x402/prepare missing 'from' field")
	}
	if _, ok := data["to"]; !ok {
		t.Fatal("x402/prepare missing 'to' field")
	}
	if _, ok := data["value"]; !ok {
		t.Fatal("x402/prepare missing 'value' field")
	}

	t.Logf("[ACCEPTANCE] x402 | prepare | hash=%s... | from=%v", hashStr[:18], data["from"])
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	return b
}

// ─── Flow 8: AP2 Discovery ───────────────────────────────────────────────────

func TestAP2Discovery(t *testing.T) {
	ctx := context.Background()

	card, err := remitmd.DiscoverAgent(ctx, acceptanceAPIURL)
	if err != nil {
		t.Fatalf("DiscoverAgent: %v", err)
	}

	if card.Name == "" {
		t.Fatal("agent card should have a name")
	}
	if card.URL == "" {
		t.Fatal("agent card should have a URL")
	}
	if len(card.Skills) == 0 {
		t.Fatal("agent card should have skills")
	}
	if card.X402.SettleEndpoint == "" {
		t.Fatal("agent card should have x402 config")
	}

	t.Logf("[ACCEPTANCE] ap2-discovery | name=%s | skills=%d | x402=%v",
		card.Name, len(card.Skills), card.X402.SettleEndpoint != "")
}

// ─── Flow 9: AP2 Payment ────────────────────────────────────────────────────

func TestAP2Payment(t *testing.T) {
	ctx := context.Background()
	agent := sharedAgent
	provider := sharedProvider
	contracts := fetchContracts(t)
	amount := 1.0

	agentBefore := getUsdcBalance(t, contracts.USDC, agent.Address())
	providerBefore := getUsdcBalance(t, contracts.USDC, provider.Address())

	card, err := remitmd.DiscoverAgent(ctx, acceptanceAPIURL)
	if err != nil {
		t.Fatalf("DiscoverAgent: %v", err)
	}

	permit, err := agent.SignPermit(ctx, "direct", amount)
	if err != nil {
		t.Fatalf("SignPermit: %v", err)
	}

	// Create A2A client from agent card + signer
	signer, err := remitmd.NewPrivateKeySigner(agent.hexKey)
	if err != nil {
		t.Fatalf("NewPrivateKeySigner: %v", err)
	}

	a2aClient, err := remitmd.A2AClientFromCard(card, signer, "base-sepolia")
	if err != nil {
		t.Fatalf("A2AClientFromCard: %v", err)
	}

	task, err := a2aClient.Send(ctx, remitmd.SendOptions{
		To:     provider.Address(),
		Amount: amount,
		Memo:   "acceptance-ap2",
		Permit: permit,
	})
	if err != nil {
		t.Fatalf("A2A Send: %v", err)
	}

	if task.Status.State != "completed" {
		t.Fatalf("A2A task not completed: state=%s", task.Status.State)
	}

	txHash := remitmd.GetTaskTxHash(task)
	if txHash != "" {
		logTx(t, "ap2-payment", fmt.Sprintf("%.1f USDC via A2A", amount), txHash)
	}

	agentAfter := waitForBalanceChange(t, contracts.USDC, agent.Address(), agentBefore)
	providerAfter := getUsdcBalance(t, contracts.USDC, provider.Address())

	assertBalanceChange(t, "agent", agentBefore, agentAfter, -amount)
	assertBalanceChange(t, "provider", providerBefore, providerAfter, amount*0.99)
}
