package remitmd

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/shopspring/decimal"
)

// Wallet is the primary remit.md client for agents that send payments.
// All payment operations are methods on Wallet.
//
// Create a Wallet with a private key:
//
//	wallet, err := remitmd.NewWallet(os.Getenv("REMITMD_KEY"))
//
// Or from environment variables:
//
//	wallet, err := remitmd.FromEnv()
type Wallet struct {
	http    remitTransport
	signer  Signer
	chainID ChainID
	chain   string
	testnet bool
}

// Option configures a Wallet.
type Option func(*walletConfig)

type walletConfig struct {
	chain         string
	testnet       bool
	baseURL       string
	routerAddress common.Address
}

// WithChain sets the target chain ("base", "arbitrum", "optimism"). Default: "base".
func WithChain(chain string) Option {
	return func(c *walletConfig) { c.chain = chain }
}

// WithTestnet targets the testnet version of the selected chain.
func WithTestnet() Option {
	return func(c *walletConfig) { c.testnet = true }
}

// WithBaseURL overrides the API base URL (useful for self-hosted or local testing).
func WithBaseURL(url string) Option {
	return func(c *walletConfig) { c.baseURL = url }
}

// WithRouterAddress sets the router contract address used in the EIP-712 domain separator.
// This must match the ROUTER_ADDRESS configured on the server.
func WithRouterAddress(addr string) Option {
	return func(c *walletConfig) { c.routerAddress = common.HexToAddress(addr) }
}

// NewWallet creates a Wallet from a hex-encoded private key.
func NewWallet(privateKey string, opts ...Option) (*Wallet, error) {
	signer, err := NewPrivateKeySigner(privateKey)
	if err != nil {
		return nil, err
	}
	return newWalletWithSigner(signer, opts...)
}

// NewWalletWithSigner creates a Wallet with a custom Signer (e.g., KMS-backed).
func NewWalletWithSigner(signer Signer, opts ...Option) (*Wallet, error) {
	return newWalletWithSigner(signer, opts...)
}

func newWalletWithSigner(signer Signer, opts ...Option) (*Wallet, error) {
	cfg := &walletConfig{chain: "base"}
	for _, o := range opts {
		o(cfg)
	}

	chainKey := cfg.chain
	if cfg.testnet {
		chainKey = cfg.chain + "-sepolia"
	}

	cc, ok := chainConfig[chainKey]
	if !ok {
		return nil, remitErr("INVALID_CHAIN",
			fmt.Sprintf("unsupported chain: %q. Valid chains: base, arbitrum, optimism. For testnet, use WithTestnet().", cfg.chain),
			map[string]any{"chain": cfg.chain},
		)
	}

	apiURL := cc.APIURL
	if cfg.baseURL != "" {
		apiURL = cfg.baseURL
	}

	return &Wallet{
		http:    newHTTPClient(apiURL, cc.ChainID, cfg.routerAddress, signer),
		signer:  signer,
		chainID: cc.ChainID,
		chain:   cfg.chain,
		testnet: cfg.testnet,
	}, nil
}

// FromEnv creates a Wallet from environment variables:
//   - REMITMD_KEY — hex-encoded private key (required)
//   - REMITMD_CHAIN — chain name (default: "base")
//   - REMITMD_TESTNET — "1", "true", or "yes" to use testnet
//   - REMITMD_ROUTER_ADDRESS — router contract address for EIP-712 domain
func FromEnv(opts ...Option) (*Wallet, error) {
	key := os.Getenv("REMITMD_KEY")
	if key == "" {
		return nil, remitErr(ErrCodeUnauthorized,
			"REMITMD_KEY environment variable is not set. Set it to your hex-encoded private key.",
			map[string]any{"hint": "export REMITMD_KEY=0x..."},
		)
	}

	envOpts := []Option{}
	if chain := os.Getenv("REMITMD_CHAIN"); chain != "" {
		envOpts = append(envOpts, WithChain(chain))
	}
	testnetEnv := os.Getenv("REMITMD_TESTNET")
	if testnetEnv == "1" || strings.EqualFold(testnetEnv, "true") || strings.EqualFold(testnetEnv, "yes") {
		envOpts = append(envOpts, WithTestnet())
	}
	if routerAddr := os.Getenv("REMITMD_ROUTER_ADDRESS"); routerAddr != "" {
		envOpts = append(envOpts, WithRouterAddress(routerAddr))
	}

	// Caller opts take precedence over env opts
	return NewWallet(key, append(envOpts, opts...)...)
}

// Address returns the Ethereum address of this wallet (checksummed).
func (w *Wallet) Address() string {
	return w.signer.Address().Hex()
}

// ChainID returns the chain ID this wallet is connected to.
func (w *Wallet) ChainID() ChainID {
	return w.chainID
}

// ─── Balance ──────────────────────────────────────────────────────────────────

// Balance returns the current USDC balance of this wallet.
func (w *Wallet) Balance(ctx context.Context) (*Balance, error) {
	var b Balance
	if err := w.http.get(ctx, "/api/v0/wallet/balance", &b); err != nil {
		return nil, err
	}
	return &b, nil
}

// ─── Direct Payment ───────────────────────────────────────────────────────────

// PayOptions configures a direct payment.
type PayOptions struct {
	Memo string
}

// PayOption configures Pay.
type PayOption func(*PayOptions)

// WithMemo sets a memo string on a payment.
func WithMemo(memo string) PayOption {
	return func(o *PayOptions) { o.Memo = memo }
}

// Pay sends a direct USDC payment to the given address.
// This is a one-way transfer with no escrow or refund mechanism.
func (w *Wallet) Pay(ctx context.Context, to string, amount decimal.Decimal, opts ...PayOption) (*Transaction, error) {
	if err := validateAddress(to); err != nil {
		return nil, err
	}
	if err := validateAmount(amount); err != nil {
		return nil, err
	}

	cfg := &PayOptions{}
	for _, o := range opts {
		o(cfg)
	}

	var tx Transaction
	err := w.http.post(ctx, "/api/v0/payments/direct", map[string]any{
		"to":     to,
		"amount": amount.String(),
		"memo":   cfg.Memo,
	}, &tx)
	if err != nil {
		return nil, err
	}
	return &tx, nil
}

// ─── Transaction History ──────────────────────────────────────────────────────

// HistoryOptions filters transaction history queries.
type HistoryOptions struct {
	Page    int
	PerPage int
	Since   *time.Time
	Until   *time.Time
}

// History returns paginated transaction history for this wallet.
func (w *Wallet) History(ctx context.Context, opts *HistoryOptions) (*TransactionList, error) {
	path := "/api/v0/wallet/history"
	if opts != nil && opts.Page > 0 {
		path += fmt.Sprintf("?page=%d&per_page=%d", opts.Page, max(opts.PerPage, 20))
	}
	var list TransactionList
	if err := w.http.get(ctx, path, &list); err != nil {
		return nil, err
	}
	return &list, nil
}

// ─── Reputation ───────────────────────────────────────────────────────────────

// Reputation returns the on-chain reputation for a given address.
func (w *Wallet) Reputation(ctx context.Context, address string) (*Reputation, error) {
	if err := validateAddress(address); err != nil {
		return nil, err
	}
	var rep Reputation
	if err := w.http.get(ctx, "/api/v0/reputation/"+address, &rep); err != nil {
		return nil, err
	}
	return &rep, nil
}

// ─── Escrow ───────────────────────────────────────────────────────────────────

// EscrowOptions configures escrow creation.
type EscrowOptions struct {
	Memo       string
	Milestones []Milestone
	Splits     []Split
	ExpiresIn  time.Duration
}

// EscrowOption configures CreateEscrow.
type EscrowOption func(*EscrowOptions)

// WithEscrowMemo sets a memo on the escrow.
func WithEscrowMemo(memo string) EscrowOption {
	return func(o *EscrowOptions) { o.Memo = memo }
}

// WithMilestones sets milestone-based partial payments on an escrow.
func WithMilestones(milestones []Milestone) EscrowOption {
	return func(o *EscrowOptions) { o.Milestones = milestones }
}

// WithSplits distributes the escrow amount among multiple recipients.
func WithSplits(splits []Split) EscrowOption {
	return func(o *EscrowOptions) { o.Splits = splits }
}

// WithEscrowExpiry sets how long the escrow remains claimable.
func WithEscrowExpiry(d time.Duration) EscrowOption {
	return func(o *EscrowOptions) { o.ExpiresIn = d }
}

// CreateEscrow creates and funds an escrow for work to be done.
// The funds are locked until the payer calls ReleaseEscrow or the escrow expires.
func (w *Wallet) CreateEscrow(ctx context.Context, payee string, amount decimal.Decimal, opts ...EscrowOption) (*Escrow, error) {
	if err := validateAddress(payee); err != nil {
		return nil, err
	}
	if err := validateAmount(amount); err != nil {
		return nil, err
	}

	cfg := &EscrowOptions{}
	for _, o := range opts {
		o(cfg)
	}

	body := map[string]any{
		"payee":  payee,
		"amount": amount.String(),
		"memo":   cfg.Memo,
	}
	if len(cfg.Milestones) > 0 {
		body["milestones"] = cfg.Milestones
	}
	if len(cfg.Splits) > 0 {
		body["splits"] = cfg.Splits
	}
	if cfg.ExpiresIn > 0 {
		body["expires_in_seconds"] = int(cfg.ExpiresIn.Seconds())
	}

	var escrow Escrow
	if err := w.http.post(ctx, "/api/v0/escrows", body, &escrow); err != nil {
		return nil, err
	}
	return &escrow, nil
}

// ReleaseEscrow releases funds to the payee, optionally releasing a specific milestone.
func (w *Wallet) ReleaseEscrow(ctx context.Context, escrowID string, milestoneID ...string) (*Transaction, error) {
	body := map[string]any{"escrow_id": escrowID}
	if len(milestoneID) > 0 {
		body["milestone_id"] = milestoneID[0]
	}
	var tx Transaction
	if err := w.http.post(ctx, "/api/v0/escrows/"+escrowID+"/release", body, &tx); err != nil {
		return nil, err
	}
	return &tx, nil
}

// CancelEscrow cancels an escrow and returns funds to the payer.
func (w *Wallet) CancelEscrow(ctx context.Context, escrowID string) (*Transaction, error) {
	var tx Transaction
	if err := w.http.post(ctx, "/api/v0/escrows/"+escrowID+"/cancel", nil, &tx); err != nil {
		return nil, err
	}
	return &tx, nil
}

// GetEscrow returns the current state of an escrow.
func (w *Wallet) GetEscrow(ctx context.Context, escrowID string) (*Escrow, error) {
	var escrow Escrow
	if err := w.http.get(ctx, "/api/v0/escrows/"+escrowID, &escrow); err != nil {
		return nil, err
	}
	return &escrow, nil
}

// ─── Tab ──────────────────────────────────────────────────────────────────────

// CreateTab opens a payment channel for batched micro-payments.
// The opener deposits up to limit USDC into the channel.
func (w *Wallet) CreateTab(ctx context.Context, counterpart string, limit decimal.Decimal, expiresIn ...time.Duration) (*Tab, error) {
	if err := validateAddress(counterpart); err != nil {
		return nil, err
	}
	body := map[string]any{
		"counterpart": counterpart,
		"limit":       limit.String(),
	}
	if len(expiresIn) > 0 {
		body["expires_in_seconds"] = int(expiresIn[0].Seconds())
	}
	var tab Tab
	if err := w.http.post(ctx, "/api/v0/tabs", body, &tab); err != nil {
		return nil, err
	}
	return &tab, nil
}

// DebitTab charges the given amount from an open tab (off-chain, signed).
func (w *Wallet) DebitTab(ctx context.Context, tabID string, amount decimal.Decimal, memo string) (*TabDebit, error) {
	body := map[string]any{
		"tab_id": tabID,
		"amount": amount.String(),
		"memo":   memo,
	}
	var debit TabDebit
	if err := w.http.post(ctx, "/api/v0/tabs/"+tabID+"/debit", body, &debit); err != nil {
		return nil, err
	}
	return &debit, nil
}

// SettleTab closes the tab and settles all charges on-chain.
func (w *Wallet) SettleTab(ctx context.Context, tabID string) (*Transaction, error) {
	var tx Transaction
	if err := w.http.post(ctx, "/api/v0/tabs/"+tabID+"/settle", nil, &tx); err != nil {
		return nil, err
	}
	return &tx, nil
}

// ─── Stream ───────────────────────────────────────────────────────────────────

// CreateStream starts a per-second USDC payment stream to a recipient.
func (w *Wallet) CreateStream(ctx context.Context, recipient string, ratePerSec decimal.Decimal, deposit decimal.Decimal) (*Stream, error) {
	if err := validateAddress(recipient); err != nil {
		return nil, err
	}
	body := map[string]any{
		"recipient":    recipient,
		"rate_per_sec": ratePerSec.String(),
		"deposit":      deposit.String(),
	}
	var stream Stream
	if err := w.http.post(ctx, "/api/v0/streams", body, &stream); err != nil {
		return nil, err
	}
	return &stream, nil
}

// WithdrawStream claims all vested stream payments (callable by recipient).
func (w *Wallet) WithdrawStream(ctx context.Context, streamID string) (*Transaction, error) {
	var tx Transaction
	if err := w.http.post(ctx, "/api/v0/streams/"+streamID+"/withdraw", nil, &tx); err != nil {
		return nil, err
	}
	return &tx, nil
}

// ─── Bounty ───────────────────────────────────────────────────────────────────

// CreateBounty posts a USDC bounty for task completion.
func (w *Wallet) CreateBounty(ctx context.Context, award decimal.Decimal, description string, expiresIn ...time.Duration) (*Bounty, error) {
	if err := validateAmount(award); err != nil {
		return nil, err
	}
	body := map[string]any{
		"award":       award.String(),
		"description": description,
	}
	if len(expiresIn) > 0 {
		body["expires_in_seconds"] = int(expiresIn[0].Seconds())
	}
	var bounty Bounty
	if err := w.http.post(ctx, "/api/v0/bounties", body, &bounty); err != nil {
		return nil, err
	}
	return &bounty, nil
}

// AwardBounty pays the bounty to the winner.
func (w *Wallet) AwardBounty(ctx context.Context, bountyID string, winner string) (*Transaction, error) {
	if err := validateAddress(winner); err != nil {
		return nil, err
	}
	body := map[string]any{
		"bounty_id": bountyID,
		"winner":    winner,
	}
	var tx Transaction
	if err := w.http.post(ctx, "/api/v0/bounties/"+bountyID+"/award", body, &tx); err != nil {
		return nil, err
	}
	return &tx, nil
}

// ─── Deposit ──────────────────────────────────────────────────────────────────

// LockDeposit locks a security deposit with a beneficiary.
func (w *Wallet) LockDeposit(ctx context.Context, beneficiary string, amount decimal.Decimal, expiresIn time.Duration) (*Deposit, error) {
	if err := validateAddress(beneficiary); err != nil {
		return nil, err
	}
	body := map[string]any{
		"beneficiary":        beneficiary,
		"amount":             amount.String(),
		"expires_in_seconds": int(expiresIn.Seconds()),
	}
	var deposit Deposit
	if err := w.http.post(ctx, "/api/v0/deposits", body, &deposit); err != nil {
		return nil, err
	}
	return &deposit, nil
}

// ─── Analytics ────────────────────────────────────────────────────────────────

// SpendingSummary returns spending analytics for a given period.
// period: "day", "week", "month", or "all"
func (w *Wallet) SpendingSummary(ctx context.Context, period string) (*SpendingSummary, error) {
	var summary SpendingSummary
	if err := w.http.get(ctx, "/api/v0/wallet/spending?period="+period, &summary); err != nil {
		return nil, err
	}
	return &summary, nil
}

// RemainingBudget returns how much the agent can still spend under operator limits.
func (w *Wallet) RemainingBudget(ctx context.Context) (*Budget, error) {
	var budget Budget
	if err := w.http.get(ctx, "/api/v0/wallet/budget", &budget); err != nil {
		return nil, err
	}
	return &budget, nil
}

// ─── Intent Negotiation ───────────────────────────────────────────────────────

// ProposeIntent proposes a payment intent for negotiation (agent-to-agent).
func (w *Wallet) ProposeIntent(ctx context.Context, to string, amount decimal.Decimal, paymentType string) (*Intent, error) {
	if err := validateAddress(to); err != nil {
		return nil, err
	}
	body := map[string]any{
		"to":     to,
		"amount": amount.String(),
		"type":   paymentType,
	}
	var intent Intent
	if err := w.http.post(ctx, "/api/v0/intents", body, &intent); err != nil {
		return nil, err
	}
	return &intent, nil
}

// ─── Validation ───────────────────────────────────────────────────────────────

func validateAddress(addr string) error {
	addr = strings.TrimSpace(addr)
	if !strings.HasPrefix(addr, "0x") && !strings.HasPrefix(addr, "0X") {
		return remitErr(ErrCodeInvalidAddress,
			fmt.Sprintf("invalid address %q: expected 0x-prefixed 40-character hex string (Ethereum address)", addr),
			map[string]any{"address": addr},
		)
	}
	if !common.IsHexAddress(addr) {
		return remitErr(ErrCodeInvalidAddress,
			fmt.Sprintf("invalid address %q: expected 0x-prefixed 40-character hex string (Ethereum address)", addr),
			map[string]any{"address": addr},
		)
	}
	return nil
}

func validateAmount(amount decimal.Decimal) error {
	minAmount := decimal.NewFromFloat(0.000001) // 1 micro-USDC (minimum on-chain unit)
	if amount.LessThan(minAmount) {
		return remitErr(ErrCodeInvalidAmount,
			fmt.Sprintf("amount %s is below minimum 0.000001 USDC (1 base unit)", amount.String()),
			map[string]any{"amount": amount.String(), "minimum": "0.000001"},
		)
	}
	maxAmount := decimal.NewFromInt(1_000_000) // 1M USDC sanity cap per transaction
	if amount.GreaterThan(maxAmount) {
		return remitErr(ErrCodeInvalidAmount,
			fmt.Sprintf("amount %s exceeds per-transaction maximum of 1,000,000 USDC", amount.String()),
			map[string]any{"amount": amount.String(), "maximum": "1000000"},
		)
	}
	return nil
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

