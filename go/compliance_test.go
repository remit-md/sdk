package remitmd_test

// Go compliance tests — run against a real server started by docker-compose.compliance.yml.
// Each test calls skipIfNoServer(t) and is individually skipped when the server is unreachable.
//
// Environment variables:
//   REMIT_TEST_SERVER_URL   Server base URL (default: http://localhost:3000)
//   REMIT_ROUTER_ADDRESS    Router contract address for EIP-712 domain
//                           (default: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8)

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	remitmd "github.com/remit-md/sdk/go"
	"github.com/shopspring/decimal"
)

// ─── Config ───────────────────────────────────────────────────────────────────

var (
	compServerURL     = envOrDefaultC("REMIT_TEST_SERVER_URL", "http://localhost:3000")
	compRouterAddress = envOrDefaultC("REMIT_ROUTER_ADDRESS", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8")
)

func envOrDefaultC(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

var (
	serverReachableOnce  sync.Once
	serverReachableValue bool
)

func isServerReachable() bool {
	serverReachableOnce.Do(func() {
		client := &http.Client{Timeout: 3 * time.Second}
		resp, err := client.Get(compServerURL + "/health")
		if err == nil {
			resp.Body.Close()
			serverReachableValue = resp.StatusCode == 200
		}
	})
	return serverReachableValue
}

func skipIfNoServer(t *testing.T) {
	t.Helper()
	if !isServerReachable() {
		t.Skipf("compliance server not reachable at %s — skipping", compServerURL)
	}
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

func doJSONC(t *testing.T, method, url string, body any, token string) map[string]any {
	t.Helper()
	var bodyReader io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		bodyReader = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, url, bodyReader)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		t.Fatalf("HTTP %s %s failed: %v", method, url, err)
	}
	defer resp.Body.Close()
	var result map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("decode response from %s: %v", url, err)
	}
	return result
}

func registerAndGetWalletC(t *testing.T) (privateKey string, walletAddress string) {
	t.Helper()
	email := fmt.Sprintf("compliance.go.%d@test.remitmd.local", time.Now().UnixMilli())

	reg := doJSONC(t, "POST", compServerURL+"/api/v0/auth/register", map[string]string{
		"email":    email,
		"password": "ComplianceTestPass1!",
	}, "")
	token, _ := reg["token"].(string)
	walletAddr, _ := reg["wallet_address"].(string)
	if token == "" {
		t.Fatalf("register: no token in response: %v", reg)
	}

	keyData := doJSONC(t, "GET", compServerURL+"/api/v0/auth/agent-key", nil, token)
	pk, _ := keyData["private_key"].(string)
	if pk == "" {
		t.Fatalf("agent-key: no private_key in response: %v", keyData)
	}
	return pk, walletAddr
}

func makeWalletC(t *testing.T, privateKey string) *remitmd.Wallet {
	t.Helper()
	w, err := remitmd.NewWallet(privateKey,
		remitmd.WithChain("base"),
		remitmd.WithTestnet(),
		remitmd.WithBaseURL(compServerURL),
		remitmd.WithRouterAddress(compRouterAddress),
	)
	if err != nil {
		t.Fatalf("NewWallet failed: %v", err)
	}
	return w
}

// requestFundsWithRetry calls mint via the SDK, retrying up to 5 times with 2-second backoff.
// Used only by TestComplianceAuth_MintCredits to verify the mint endpoint works.
func requestFundsWithRetry(t *testing.T, w *remitmd.Wallet) {
	t.Helper()
	var lastErr error
	for attempt := 0; attempt < 5; attempt++ {
		if attempt > 0 {
			time.Sleep(2 * time.Second)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		_, lastErr = w.Mint(ctx, 100)
		cancel()
		if lastErr == nil {
			return
		}
	}
	t.Fatalf("mint failed after 5 attempts: %v", lastErr)
}

// ─── Shared funded payer ──────────────────────────────────────────────────────

var (
	oncePayer   sync.Once
	sharedPayer *remitmd.Wallet
)

// getSharedPayer returns (or lazily creates) a single funded test payer wallet
// with 1000 USDC. All payment tests share this wallet so only one mint call
// is needed per test run, avoiding the per-wallet-per-hour rate limit.
func getSharedPayer(t *testing.T) *remitmd.Wallet {
	t.Helper()
	oncePayer.Do(func() {
		pk, addr := registerAndGetWalletC(t)
		// Fund with 1000 USDC via direct HTTP — mint is public (no EIP-712 auth required).
		resp := doJSONC(t, "POST", compServerURL+"/api/v0/mint", map[string]any{
			"wallet": addr,
			"amount": 1000,
		}, "")
		if resp["tx_hash"] == nil {
			t.Fatalf("mint: no tx_hash in response (wallet=%s): %v", addr, resp)
		}
		sharedPayer = makeWalletC(t, pk)
	})
	if sharedPayer == nil {
		t.Fatalf("shared payer not initialized (previous setup failed)")
	}
	return sharedPayer
}

// makeFundedPairC returns the shared funded payer and a fresh payee wallet.
// Only one mint call is made for the entire test run (via getSharedPayer).
func makeFundedPairC(t *testing.T) (payer *remitmd.Wallet, payee *remitmd.Wallet, payeeAddr string) {
	t.Helper()
	pkB, addrB := registerAndGetWalletC(t)
	payee = makeWalletC(t, pkB)
	payer = getSharedPayer(t)
	return payer, payee, addrB
}

// ─── Auth tests ───────────────────────────────────────────────────────────────

func TestComplianceAuth_AuthenticatedRequestSucceeds(t *testing.T) {
	skipIfNoServer(t)
	pk, addr := registerAndGetWalletC(t)
	wallet := makeWalletC(t, pk)

	// Verify authenticated wallet creation: address must be non-empty and match server.
	if wallet.Address() == "" {
		t.Fatal("wallet address is empty after registration")
	}
	// Server returns lowercase addresses; SDK returns EIP-55 checksummed. Compare case-insensitively.
	if !strings.EqualFold(wallet.Address(), addr) {
		t.Errorf("address mismatch: sdk=%s server=%s", wallet.Address(), addr)
	}
}

func TestComplianceAuth_MintCredits(t *testing.T) {
	skipIfNoServer(t)
	pk, _ := registerAndGetWalletC(t)
	wallet := makeWalletC(t, pk)

	// requestFundsWithRetry handles the global mint rate limit.
	requestFundsWithRetry(t, wallet)
}

// ─── Payment tests ────────────────────────────────────────────────────────────

func TestCompliancePayDirect_HappyPath(t *testing.T) {
	skipIfNoServer(t)
	payer, _, payeeAddr := makeFundedPairC(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	tx, err := payer.Pay(ctx, payeeAddr, decimal.NewFromFloat(5.0), remitmd.WithMemo("compliance test"))
	if err != nil {
		t.Fatalf("Pay() failed: %v", err)
	}
	if tx.TxHash == "" {
		t.Error("tx_hash must be non-empty")
	}
}

func TestCompliancePayDirect_BelowMinimumReturnsError(t *testing.T) {
	skipIfNoServer(t)
	payer, _, payeeAddr := makeFundedPairC(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	_, err := payer.Pay(ctx, payeeAddr, decimal.NewFromFloat(0.001))
	if err == nil {
		t.Fatal("expected error for amount below minimum, got nil")
	}
}

func TestCompliancePayDirect_SelfPaymentReturnsError(t *testing.T) {
	skipIfNoServer(t)
	// Reuse shared payer — self-payment should be rejected by the server.
	wallet := getSharedPayer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_, err := wallet.Pay(ctx, wallet.Address(), decimal.NewFromFloat(1.0), remitmd.WithMemo("self pay"))
	if err == nil {
		t.Fatal("expected error for self-payment, got nil")
	}
}

// ─── Escrow tests ─────────────────────────────────────────────────────────────

func TestComplianceEscrow_CreateReturnsFunded(t *testing.T) {
	skipIfNoServer(t)
	payer, _, payeeAddr := makeFundedPairC(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	escrow, err := payer.CreateEscrow(ctx, payeeAddr, decimal.NewFromFloat(10.0),
		remitmd.WithEscrowMemo("compliance escrow test"))
	if err != nil {
		t.Fatalf("CreateEscrow() failed: %v", err)
	}
	if escrow.InvoiceID == "" {
		t.Error("invoice_id must be non-empty")
	}
	if escrow.TxHash == "" {
		t.Error("tx_hash must be non-empty")
	}
	if escrow.Status != remitmd.EscrowStatusFunded {
		t.Errorf("expected status %s, got %s", remitmd.EscrowStatusFunded, escrow.Status)
	}
}

func TestComplianceEscrow_GetEscrowAfterCreate(t *testing.T) {
	skipIfNoServer(t)
	payer, _, payeeAddr := makeFundedPairC(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	escrow, err := payer.CreateEscrow(ctx, payeeAddr, decimal.NewFromFloat(10.0))
	if err != nil {
		t.Fatalf("CreateEscrow() failed: %v", err)
	}

	fetched, err := payer.GetEscrow(ctx, escrow.InvoiceID)
	if err != nil {
		t.Fatalf("GetEscrow() failed: %v", err)
	}
	if fetched.InvoiceID != escrow.InvoiceID {
		t.Errorf("invoice_id mismatch: got %s, want %s", fetched.InvoiceID, escrow.InvoiceID)
	}
	if fetched.Status != remitmd.EscrowStatusFunded {
		t.Errorf("expected status funded, got %s", fetched.Status)
	}
}

func TestComplianceEscrow_CancelTransitionsStatus(t *testing.T) {
	skipIfNoServer(t)
	payer, _, payeeAddr := makeFundedPairC(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	escrow, err := payer.CreateEscrow(ctx, payeeAddr, decimal.NewFromFloat(10.0),
		remitmd.WithEscrowMemo("to be cancelled"))
	if err != nil {
		t.Fatalf("CreateEscrow() failed: %v", err)
	}

	cancelled, err := payer.CancelEscrow(ctx, escrow.InvoiceID)
	if err != nil {
		t.Fatalf("CancelEscrow() failed: %v", err)
	}
	if cancelled.Status != remitmd.EscrowStatusCancelled {
		t.Errorf("expected status cancelled, got %s", cancelled.Status)
	}
}

// ─── Tab tests ────────────────────────────────────────────────────────────────

func TestComplianceTab_OpenReturnsOpenState(t *testing.T) {
	skipIfNoServer(t)
	payer, _, payeeAddr := makeFundedPairC(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	tab, err := payer.CreateTab(ctx, payeeAddr,
		decimal.NewFromFloat(20.0),
		decimal.NewFromFloat(0.10))
	if err != nil {
		t.Fatalf("CreateTab() failed: %v", err)
	}
	if tab.ID == "" {
		t.Error("tab id must be non-empty")
	}
	if tab.Status != remitmd.TabStatusOpen {
		t.Errorf("expected status open, got %s", tab.Status)
	}
}

func TestComplianceTab_CloseSettlesTab(t *testing.T) {
	skipIfNoServer(t)
	payer, _, payeeAddr := makeFundedPairC(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	tab, err := payer.CreateTab(ctx, payeeAddr,
		decimal.NewFromFloat(50.0),
		decimal.NewFromFloat(1.0))
	if err != nil {
		t.Fatalf("CreateTab() failed: %v", err)
	}

	closed, err := payer.CloseTab(ctx, tab.ID)
	if err != nil {
		t.Fatalf("CloseTab() failed: %v", err)
	}
	if closed.TxHash == "" {
		t.Error("closed tab must have tx_hash")
	}

	fetched, err := payer.GetTab(ctx, tab.ID)
	if err != nil {
		t.Fatalf("GetTab() after close failed: %v", err)
	}
	if fetched.Status == remitmd.TabStatusOpen {
		t.Error("tab must not be in open state after close")
	}
}
