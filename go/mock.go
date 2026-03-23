package remitmd

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/shopspring/decimal"
)

// MockRemit is an in-memory mock for testing agents that use remit.md.
// Zero network, zero latency, deterministic — ideal for unit tests.
//
//	mock := remitmd.NewMockRemit()
//	wallet := mock.Wallet()
//
//	tx, err := wallet.Pay(ctx, "0xRecipient", decimal.NewFromFloat(1.50))
//	require.NoError(t, err)
//	assert.True(t, mock.WasPaid("0xRecipient", decimal.NewFromFloat(1.50)))
type MockRemit struct {
	mu              sync.Mutex
	transactions    []Transaction
	escrows         map[string]*Escrow
	pendingInvoices map[string]mockPendingInvoice
	tabs            map[string]*Tab
	streams         map[string]*Stream
	bounties        map[string]*Bounty
	deposits        map[string]*Deposit
	balance         decimal.Decimal
}

// mockPendingInvoice holds invoice data between POST /invoices and POST /escrows.
type mockPendingInvoice struct {
	Payee  string
	Amount decimal.Decimal
	Memo   string
}

// NewMockRemit creates a MockRemit with a default starting balance of 10,000 USDC.
func NewMockRemit(startingBalance ...decimal.Decimal) *MockRemit {
	bal := decimal.NewFromInt(10_000)
	if len(startingBalance) > 0 {
		bal = startingBalance[0]
	}
	return &MockRemit{
		balance:         bal,
		escrows:         make(map[string]*Escrow),
		pendingInvoices: make(map[string]mockPendingInvoice),
		tabs:            make(map[string]*Tab),
		streams:         make(map[string]*Stream),
		bounties:        make(map[string]*Bounty),
		deposits:        make(map[string]*Deposit),
	}
}

// Wallet returns a Wallet backed by this MockRemit. No private key required.
func (m *MockRemit) Wallet() *Wallet {
	return &Wallet{
		http:     &mockTransport{mock: m},
		signer:   &mockSigner{},
		chainID:  ChainBaseSep,
		chain:    "base",
		chainKey: "base-sepolia",
		testnet:  true,
		rpcURL:   "", // empty = skip RPC calls in mock mode
		contractsCache: &ContractAddresses{
			ChainID: int(ChainBaseSep),
			USDC:    "0x2d846325766921935f37d5b4478196d3ef93707c",
			Router:  "0x3120f396ff6a9afc5a9d92e28796082f1429e024",
			Escrow:  "0x47de7cdd757e3765d36c083dab59b2c5a9d249f2",
			Tab:     "0x9415f510d8c6199e0f66bde927d7d88de391f5e8",
			Stream:  "0x20d413e0eac0f5da3c8630667fd16a94fcd7231a",
			Bounty:  "0xb3868471c3034280cce3a56dd37c6154c3bb0b32",
			Deposit: "0x7e0ae37df62e93c1c16a5661a7998bd174331554",
		},
	}
}

// Reset clears all recorded state. Call between test cases.
func (m *MockRemit) Reset() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.transactions = nil
	m.escrows = make(map[string]*Escrow)
	m.pendingInvoices = make(map[string]mockPendingInvoice)
	m.tabs = make(map[string]*Tab)
	m.streams = make(map[string]*Stream)
	m.bounties = make(map[string]*Bounty)
	m.deposits = make(map[string]*Deposit)
}

// SetBalance overrides the mock wallet's simulated USDC balance.
func (m *MockRemit) SetBalance(amount decimal.Decimal) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.balance = amount
}

// Transactions returns all transactions recorded by this mock.
func (m *MockRemit) Transactions() []Transaction {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Transaction, len(m.transactions))
	copy(out, m.transactions)
	return out
}

// WasPaid returns true if a payment of exactly amount USDC was sent to recipient.
func (m *MockRemit) WasPaid(recipient string, amount decimal.Decimal) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, tx := range m.transactions {
		if strings.EqualFold(tx.To, recipient) && tx.Amount.Equal(amount) {
			return true
		}
	}
	return false
}

// TotalPaidTo returns the sum of all USDC paid to a recipient.
func (m *MockRemit) TotalPaidTo(recipient string) decimal.Decimal {
	m.mu.Lock()
	defer m.mu.Unlock()
	total := decimal.Zero
	for _, tx := range m.transactions {
		if strings.EqualFold(tx.To, recipient) {
			total = total.Add(tx.Amount)
		}
	}
	return total
}

// ─── mockTransport implements remitTransport ──────────────────────────────────

type mockTransport struct {
	mock *MockRemit
}

func (t *mockTransport) post(ctx context.Context, path string, body any, dst any) error {
	return t.dispatch(ctx, "POST", path, body, dst)
}

func (t *mockTransport) get(ctx context.Context, path string, dst any) error {
	return t.dispatch(ctx, "GET", path, nil, dst)
}

func (t *mockTransport) dispatch(_ context.Context, method, path string, body any, dst any) error {
	m := t.mock

	// Route to handler based on path + method
	switch {
	case method == "GET" && path == "/api/v1/wallet/balance":
		return t.respond(dst, m.mockBalance())

	case method == "POST" && path == "/api/v1/payments/direct":
		b := mustBody(body)
		to := b["to"].(string)
		amount := mustDecimal(b["amount"])
		memo, _ := b["task"].(string)
		tx, err := m.mockPay(to, amount, memo)
		if err != nil {
			return err
		}
		return t.respond(dst, tx)

	case method == "POST" && path == "/api/v1/invoices":
		b := mustBody(body)
		id, _ := b["id"].(string)
		payee, _ := b["to_agent"].(string)
		amount := mustDecimal(b["amount"])
		memo, _ := b["task"].(string)
		m.mu.Lock()
		m.pendingInvoices[id] = mockPendingInvoice{Payee: payee, Amount: amount, Memo: memo}
		m.mu.Unlock()
		return nil

	case method == "POST" && path == "/api/v1/escrows":
		b := mustBody(body)
		invoiceID, _ := b["invoice_id"].(string)
		m.mu.Lock()
		inv, ok := m.pendingInvoices[invoiceID]
		if ok {
			delete(m.pendingInvoices, invoiceID)
		}
		m.mu.Unlock()
		if !ok {
			return remitErr(ErrCodeEscrowNotFound, "invoice not found in mock", nil)
		}
		escrow, err := m.mockCreateEscrow(inv.Payee, inv.Amount, inv.Memo)
		if err != nil {
			return err
		}
		return t.respond(dst, escrow)

	case method == "POST" && strings.HasSuffix(path, "/claim-start"):
		escrowID := extractID(path, "/api/v1/escrows/", "/claim-start")
		escrow, err := m.mockClaimStart(escrowID)
		if err != nil {
			return err
		}
		return t.respond(dst, escrow)

	case method == "POST" && strings.HasSuffix(path, "/release"):
		escrowID := extractID(path, "/api/v1/escrows/", "/release")
		escrow, err := m.mockReleaseEscrow(escrowID)
		if err != nil {
			return err
		}
		return t.respond(dst, escrow)

	case method == "POST" && strings.HasSuffix(path, "/cancel"):
		escrowID := extractID(path, "/api/v1/escrows/", "/cancel")
		escrow, err := m.mockCancelEscrow(escrowID)
		if err != nil {
			return err
		}
		return t.respond(dst, escrow)

	case method == "GET" && strings.HasPrefix(path, "/api/v1/escrows/"):
		escrowID := strings.TrimPrefix(path, "/api/v1/escrows/")
		return t.respond(dst, m.mockGetEscrow(escrowID))

	case method == "GET" && strings.HasPrefix(path, "/api/v1/reputation/"):
		address := strings.TrimPrefix(path, "/api/v1/reputation/")
		return t.respond(dst, m.mockReputation(address))

	case method == "GET" && strings.HasPrefix(path, "/api/v1/wallet/spending"):
		return t.respond(dst, m.mockSpendingSummary())

	case method == "GET" && path == "/api/v1/wallet/budget":
		return t.respond(dst, m.mockBudget())

	case method == "GET" && strings.HasPrefix(path, "/api/v1/wallet/history"):
		return t.respond(dst, m.mockHistory())

	default:
		// Unhandled routes succeed with an empty response (permissive mock)
		return nil
	}
}

func (t *mockTransport) respond(dst any, src any) error {
	if dst == nil {
		return nil
	}
	b, _ := json.Marshal(src)
	return json.Unmarshal(b, dst)
}

// ─── Mock handlers ────────────────────────────────────────────────────────────

func (m *MockRemit) mockBalance() *Balance {
	m.mu.Lock()
	defer m.mu.Unlock()
	return &Balance{
		USDC:      m.balance,
		Address:   "0xMockWallet0000000000000000000000000000001",
		ChainID:   ChainBaseSep,
		UpdatedAt: time.Now(),
	}
}

func (m *MockRemit) mockPay(to string, amount decimal.Decimal, memo string) (*Transaction, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.balance.LessThan(amount) {
		return nil, remitErr(ErrCodeInsufficientFunds,
			fmt.Sprintf("insufficient balance: have %s USDC, need %s USDC", m.balance.String(), amount.String()),
			map[string]any{"balance": m.balance.String(), "amount": amount.String()},
		)
	}
	m.balance = m.balance.Sub(amount)
	tx := Transaction{
		ID:        newID("tx"),
		TxHash:    "0x" + randomHex(32),
		From:      "0xMockWallet0000000000000000000000000000001",
		To:        to,
		Amount:    amount,
		Fee:       decimal.NewFromFloat(0.001),
		Memo:      memo,
		ChainID:   ChainBaseSep,
		CreatedAt: time.Now(),
	}
	m.transactions = append(m.transactions, tx)
	return &tx, nil
}

func (m *MockRemit) mockCreateEscrow(payee string, amount decimal.Decimal, memo string) (*Escrow, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.balance.LessThan(amount) {
		return nil, remitErr(ErrCodeInsufficientFunds,
			fmt.Sprintf("insufficient balance for escrow: have %s USDC, need %s USDC", m.balance.String(), amount.String()),
			nil,
		)
	}
	m.balance = m.balance.Sub(amount)
	escrow := &Escrow{
		InvoiceID: newID("esc"),
		Chain:     "base-sepolia",
		TxHash:    "0x" + randomHex(32),
		Payer:     "0xMockWallet0000000000000000000000000000001",
		Payee:     payee,
		Amount:    amount,
		Fee:       decimal.NewFromFloat(0.001),
		Status:    EscrowStatusFunded,
	}
	m.escrows[escrow.InvoiceID] = escrow
	return escrow, nil
}

func (m *MockRemit) mockClaimStart(escrowID string) (*Escrow, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	escrow, ok := m.escrows[escrowID]
	if !ok {
		return nil, remitErr(ErrCodeEscrowNotFound,
			fmt.Sprintf("escrow %q not found", escrowID),
			map[string]any{"escrow_id": escrowID},
		)
	}
	escrow.ClaimStarted = true
	return escrow, nil
}

func (m *MockRemit) mockReleaseEscrow(escrowID string) (*Escrow, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	escrow, ok := m.escrows[escrowID]
	if !ok {
		return nil, remitErr(ErrCodeEscrowNotFound,
			fmt.Sprintf("escrow %q not found", escrowID),
			map[string]any{"escrow_id": escrowID},
		)
	}
	escrow.Status = EscrowStatusReleased
	return escrow, nil
}

func (m *MockRemit) mockCancelEscrow(escrowID string) (*Escrow, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	escrow, ok := m.escrows[escrowID]
	if !ok {
		return nil, remitErr(ErrCodeEscrowNotFound,
			fmt.Sprintf("escrow %q not found", escrowID),
			map[string]any{"escrow_id": escrowID},
		)
	}
	escrow.Status = EscrowStatusCancelled
	// Return funds to payer's balance
	m.balance = m.balance.Add(escrow.Amount)
	return escrow, nil
}

func (m *MockRemit) mockGetEscrow(escrowID string) *Escrow {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.escrows[escrowID]
}

func (m *MockRemit) mockReputation(address string) *Reputation {
	return &Reputation{
		Address:          address,
		Score:            750,
		TotalPaid:        decimal.NewFromInt(1000),
		TotalReceived:    decimal.NewFromInt(500),
		TransactionCount: 42,
		MemberSince:      time.Now().Add(-30 * 24 * time.Hour),
	}
}

func (m *MockRemit) mockSpendingSummary() *SpendingSummary {
	m.mu.Lock()
	defer m.mu.Unlock()
	total := decimal.Zero
	for _, tx := range m.transactions {
		total = total.Add(tx.Amount)
	}
	return &SpendingSummary{
		Address:    "0xMockWallet0000000000000000000000000000001",
		Period:     "month",
		TotalSpent: total,
		TotalFees:  decimal.NewFromFloat(0.001).Mul(decimal.NewFromInt(int64(len(m.transactions)))),
		TxCount:    len(m.transactions),
	}
}

func (m *MockRemit) mockBudget() *Budget {
	return &Budget{
		DailyLimit:       decimal.NewFromInt(10_000),
		DailyUsed:        decimal.Zero,
		DailyRemaining:   decimal.NewFromInt(10_000),
		MonthlyLimit:     decimal.NewFromInt(100_000),
		MonthlyUsed:      decimal.Zero,
		MonthlyRemaining: decimal.NewFromInt(100_000),
		PerTxLimit:       decimal.NewFromInt(1_000),
	}
}

func (m *MockRemit) mockHistory() *TransactionList {
	m.mu.Lock()
	defer m.mu.Unlock()
	items := make([]Transaction, len(m.transactions))
	copy(items, m.transactions)
	return &TransactionList{
		Items:   items,
		Total:   len(items),
		Page:    1,
		PerPage: 50,
		HasMore: false,
	}
}

// ─── mockSigner ───────────────────────────────────────────────────────────────

type mockSigner struct{}

func (s *mockSigner) Sign(_ [32]byte) ([]byte, error) {
	return make([]byte, 65), nil
}

func (s *mockSigner) Address() common.Address {
	return common.HexToAddress("0x0000000000000000000000000000000000000001")
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

func newID(prefix string) string {
	return prefix + "_" + randomHex(8)
}

func randomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b) //nolint:errcheck // crypto/rand.Read never fails
	return hex.EncodeToString(b)
}

func mustBody(body any) map[string]any {
	b, _ := json.Marshal(body)
	var m map[string]any
	json.Unmarshal(b, &m) //nolint:errcheck
	return m
}

func mustDecimal(v any) decimal.Decimal {
	switch val := v.(type) {
	case string:
		d, _ := decimal.NewFromString(val)
		return d
	case float64:
		return decimal.NewFromFloat(val)
	default:
		return decimal.Zero
	}
}

func extractID(path, prefix, suffix string) string {
	s := strings.TrimPrefix(path, prefix)
	return strings.TrimSuffix(s, suffix)
}
