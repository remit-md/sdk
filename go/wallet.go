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
	http           remitTransport
	signer         Signer
	chainID        ChainID
	chain          string
	testnet        bool
	contractsCache *ContractAddresses
}

// Option configures a Wallet.
type Option func(*walletConfig)

type walletConfig struct {
	chain         string
	testnet       bool
	baseURL       string
	routerAddress common.Address
}

// WithChain sets the target chain. Currently only "base" is supported. Default: "base".
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
			fmt.Sprintf("unsupported chain: %q. Valid chains: base. For testnet, use WithTestnet().", cfg.chain),
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
	Memo   string
	Permit *PermitSignature
}

// PayOption configures Pay.
type PayOption func(*PayOptions)

// WithMemo sets a memo string on a payment.
func WithMemo(memo string) PayOption {
	return func(o *PayOptions) { o.Memo = memo }
}

// WithPayPermit attaches an EIP-2612 permit signature to a direct payment.
func WithPayPermit(permit *PermitSignature) PayOption {
	return func(o *PayOptions) { o.Permit = permit }
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

	body := map[string]any{
		"to":        to,
		"amount":    amount.InexactFloat64(),
		"task":      cfg.Memo,
		"chain":     w.chain,
		"nonce":     randomHex(16),
		"signature": "0x",
	}
	if cfg.Permit != nil {
		body["permit"] = cfg.Permit
	}
	var tx Transaction
	if err := w.http.post(ctx, "/api/v0/payments/direct", body, &tx); err != nil {
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
	Permit     *PermitSignature
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

// WithEscrowPermit attaches an EIP-2612 permit signature to an escrow.
func WithEscrowPermit(permit *PermitSignature) EscrowOption {
	return func(o *EscrowOptions) { o.Permit = permit }
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

	// Step 1: create the invoice.
	invoiceID := randomHex(16)
	invBody := map[string]any{
		"id":         invoiceID,
		"chain":      w.chain,
		"from_agent": strings.ToLower(w.Address()),
		"to_agent":   strings.ToLower(payee),
		"amount":     amount.InexactFloat64(),
		"type":       "escrow",
		"task":       cfg.Memo,
		"nonce":      randomHex(16),
		"signature":  "0x",
	}
	if cfg.ExpiresIn > 0 {
		invBody["escrow_timeout"] = int(cfg.ExpiresIn.Seconds())
	}
	if err := w.http.post(ctx, "/api/v0/invoices", invBody, nil); err != nil {
		return nil, err
	}

	// Step 2: fund the escrow.
	escrowBody := map[string]any{"invoice_id": invoiceID}
	if cfg.Permit != nil {
		escrowBody["permit"] = cfg.Permit
	}
	var escrow Escrow
	if err := w.http.post(ctx, "/api/v0/escrows", escrowBody, &escrow); err != nil {
		return nil, err
	}
	return &escrow, nil
}

// ReleaseEscrow releases funds to the payee, optionally releasing specific milestones.
func (w *Wallet) ReleaseEscrow(ctx context.Context, escrowID string, milestoneIDs ...string) (*Escrow, error) {
	body := map[string]any{}
	if len(milestoneIDs) > 0 {
		body["milestone_ids"] = milestoneIDs
	}
	var escrow Escrow
	if err := w.http.post(ctx, "/api/v0/escrows/"+escrowID+"/release", body, &escrow); err != nil {
		return nil, err
	}
	return &escrow, nil
}

// ClaimStart signals that the payee has started work on an escrow.
// Must be called by the payee before the payer can release funds.
func (w *Wallet) ClaimStart(ctx context.Context, escrowID string) (*Escrow, error) {
	var escrow Escrow
	if err := w.http.post(ctx, "/api/v0/escrows/"+escrowID+"/claim-start", map[string]any{}, &escrow); err != nil {
		return nil, err
	}
	return &escrow, nil
}

// CancelEscrow cancels an escrow and returns funds to the payer.
func (w *Wallet) CancelEscrow(ctx context.Context, escrowID string) (*Escrow, error) {
	var escrow Escrow
	if err := w.http.post(ctx, "/api/v0/escrows/"+escrowID+"/cancel", map[string]any{}, &escrow); err != nil {
		return nil, err
	}
	return &escrow, nil
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

// TabOptions configures tab creation.
type TabOptions struct {
	ExpiresIn time.Duration
	Permit    *PermitSignature
}

// TabOption configures CreateTab.
type TabOption func(*TabOptions)

// WithTabExpiry sets how long the tab remains open. Default: 24h.
func WithTabExpiry(d time.Duration) TabOption {
	return func(o *TabOptions) { o.ExpiresIn = d }
}

// WithTabPermit attaches an EIP-2612 permit signature to a tab.
func WithTabPermit(permit *PermitSignature) TabOption {
	return func(o *TabOptions) { o.Permit = permit }
}

// CreateTab opens a metered payment tab. The payer pre-funds up to limit USDC;
// the provider charges perUnit USDC per API call.
func (w *Wallet) CreateTab(ctx context.Context, provider string, limit decimal.Decimal, perUnit decimal.Decimal, opts ...TabOption) (*Tab, error) {
	if err := validateAddress(provider); err != nil {
		return nil, err
	}
	cfg := &TabOptions{ExpiresIn: 24 * time.Hour}
	for _, o := range opts {
		o(cfg)
	}
	body := map[string]any{
		"chain":        w.chain,
		"provider":     provider,
		"limit_amount": limit.InexactFloat64(),
		"per_unit":     perUnit.InexactFloat64(),
		"expiry":       int(time.Now().Unix()) + int(cfg.ExpiresIn.Seconds()),
	}
	if cfg.Permit != nil {
		body["permit"] = cfg.Permit
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
		"amount": amount.InexactFloat64(),
		"memo":   memo,
	}
	var debit TabDebit
	if err := w.http.post(ctx, "/api/v0/tabs/"+tabID+"/debit", body, &debit); err != nil {
		return nil, err
	}
	return &debit, nil
}

// GetTab returns the current state of a tab.
func (w *Wallet) GetTab(ctx context.Context, tabID string) (*Tab, error) {
	var tab Tab
	if err := w.http.get(ctx, "/api/v0/tabs/"+tabID, &tab); err != nil {
		return nil, err
	}
	return &tab, nil
}

// CloseTabOptions configures CloseTab.
type CloseTabOptions struct {
	FinalAmount float64
	ProviderSig string
}

// CloseTabOption configures CloseTab.
type CloseTabOption func(*CloseTabOptions)

// WithCloseTabAmount sets the final settlement amount.
func WithCloseTabAmount(amount float64) CloseTabOption {
	return func(o *CloseTabOptions) { o.FinalAmount = amount }
}

// WithCloseTabSig sets the provider EIP-712 signature for settlement.
func WithCloseTabSig(sig string) CloseTabOption {
	return func(o *CloseTabOptions) { o.ProviderSig = sig }
}

// CloseTab settles all charges on-chain and closes the tab.
func (w *Wallet) CloseTab(ctx context.Context, tabID string, opts ...CloseTabOption) (*Tab, error) {
	cfg := &CloseTabOptions{ProviderSig: "0x"}
	for _, o := range opts {
		o(cfg)
	}
	var tab Tab
	if err := w.http.post(ctx, "/api/v0/tabs/"+tabID+"/close", map[string]any{
		"final_amount": cfg.FinalAmount,
		"provider_sig": cfg.ProviderSig,
	}, &tab); err != nil {
		return nil, err
	}
	return &tab, nil
}

// SettleTab is an alias for CloseTab for backward compatibility.
func (w *Wallet) SettleTab(ctx context.Context, tabID string) (*Tab, error) {
	return w.CloseTab(ctx, tabID)
}

// ChargeTab charges the given amount from an open tab using EIP-712 signed authorization.
func (w *Wallet) ChargeTab(ctx context.Context, tabID string, amount, cumulative float64, callCount int, providerSig string) (*TabCharge, error) {
	var charge TabCharge
	if err := w.http.post(ctx, "/api/v0/tabs/"+tabID+"/charge", map[string]any{
		"amount":       amount,
		"cumulative":   cumulative,
		"call_count":   callCount,
		"provider_sig": providerSig,
	}, &charge); err != nil {
		return nil, err
	}
	return &charge, nil
}

// ─── Stream ───────────────────────────────────────────────────────────────────

// StreamOptions configures stream creation.
type StreamOptions struct {
	Permit *PermitSignature
}

// StreamOption configures CreateStream.
type StreamOption func(*StreamOptions)

// WithStreamPermit attaches an EIP-2612 permit signature to a stream.
func WithStreamPermit(permit *PermitSignature) StreamOption {
	return func(o *StreamOptions) { o.Permit = permit }
}

// CreateStream starts a per-second USDC payment stream to a payee.
func (w *Wallet) CreateStream(ctx context.Context, payee string, ratePerSecond decimal.Decimal, maxTotal decimal.Decimal, opts ...StreamOption) (*Stream, error) {
	if err := validateAddress(payee); err != nil {
		return nil, err
	}
	cfg := &StreamOptions{}
	for _, o := range opts {
		o(cfg)
	}
	body := map[string]any{
		"chain":           w.chain,
		"payee":           payee,
		"rate_per_second": ratePerSecond.String(),
		"max_total":       maxTotal.String(),
	}
	if cfg.Permit != nil {
		body["permit"] = cfg.Permit
	}
	var stream Stream
	if err := w.http.post(ctx, "/api/v0/streams", body, &stream); err != nil {
		return nil, err
	}
	return &stream, nil
}

// CloseStream closes an active payment stream.
func (w *Wallet) CloseStream(ctx context.Context, streamID string) (*Stream, error) {
	var stream Stream
	if err := w.http.post(ctx, "/api/v0/streams/"+streamID+"/close", map[string]any{}, &stream); err != nil {
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

// BountyOptions configures bounty creation.
type BountyOptions struct {
	MaxAttempts int
	Permit      *PermitSignature
}

// BountyOption configures CreateBounty.
type BountyOption func(*BountyOptions)

// WithBountyMaxAttempts sets the maximum number of submission attempts allowed.
func WithBountyMaxAttempts(n int) BountyOption {
	return func(o *BountyOptions) { o.MaxAttempts = n }
}

// WithBountyPermit attaches an EIP-2612 permit signature to a bounty.
func WithBountyPermit(permit *PermitSignature) BountyOption {
	return func(o *BountyOptions) { o.Permit = permit }
}

// CreateBounty posts a USDC bounty for task completion.
func (w *Wallet) CreateBounty(ctx context.Context, amount decimal.Decimal, task string, deadline int64, opts ...BountyOption) (*Bounty, error) {
	if err := validateAmount(amount); err != nil {
		return nil, err
	}
	cfg := &BountyOptions{MaxAttempts: 10}
	for _, o := range opts {
		o(cfg)
	}
	body := map[string]any{
		"chain":            w.chain,
		"amount":           amount.InexactFloat64(),
		"task_description": task,
		"deadline":         deadline,
		"max_attempts":     cfg.MaxAttempts,
	}
	if cfg.Permit != nil {
		body["permit"] = cfg.Permit
	}
	var bounty Bounty
	if err := w.http.post(ctx, "/api/v0/bounties", body, &bounty); err != nil {
		return nil, err
	}
	return &bounty, nil
}

// SubmitBounty submits evidence to claim a bounty.
func (w *Wallet) SubmitBounty(ctx context.Context, bountyID string, evidenceHash string) (*BountySubmission, error) {
	var sub BountySubmission
	if err := w.http.post(ctx, "/api/v0/bounties/"+bountyID+"/submit", map[string]any{
		"evidence_hash": evidenceHash,
	}, &sub); err != nil {
		return nil, err
	}
	return &sub, nil
}

// AwardBounty awards the bounty to a specific submission.
func (w *Wallet) AwardBounty(ctx context.Context, bountyID string, submissionID int) (*Bounty, error) {
	var bounty Bounty
	if err := w.http.post(ctx, "/api/v0/bounties/"+bountyID+"/award", map[string]any{
		"submission_id": submissionID,
	}, &bounty); err != nil {
		return nil, err
	}
	return &bounty, nil
}

// BountyListOptions controls filtering for ListBounties.
type BountyListOptions struct {
	Status    string // Filter by status (open, claimed, awarded, expired).
	Poster    string // Filter by poster wallet address.
	Submitter string // Filter by submitter wallet address.
	Limit     int    // Max results (default 20, max 100).
	Offset    int    // Pagination offset.
}

// ListBounties returns bounties matching the given filters.
func (w *Wallet) ListBounties(ctx context.Context, opts *BountyListOptions) ([]Bounty, error) {
	path := "/api/v0/bounties"
	params := make([]string, 0, 5)
	if opts != nil {
		if opts.Status != "" {
			params = append(params, "status="+opts.Status)
		}
		if opts.Poster != "" {
			params = append(params, "poster="+opts.Poster)
		}
		if opts.Submitter != "" {
			params = append(params, "submitter="+opts.Submitter)
		}
		if opts.Limit > 0 {
			params = append(params, fmt.Sprintf("limit=%d", opts.Limit))
		}
		if opts.Offset > 0 {
			params = append(params, fmt.Sprintf("offset=%d", opts.Offset))
		}
	}
	if len(params) > 0 {
		path += "?" + strings.Join(params, "&")
	}
	var resp struct {
		Data []Bounty `json:"data"`
	}
	if err := w.http.get(ctx, path, &resp); err != nil {
		return nil, err
	}
	return resp.Data, nil
}

// ─── Deposit ──────────────────────────────────────────────────────────────────

// DepositOptions configures deposit creation.
type DepositOptions struct {
	Permit *PermitSignature
}

// DepositOption configures PlaceDeposit.
type DepositOption func(*DepositOptions)

// WithDepositPermit attaches an EIP-2612 permit signature to a deposit.
func WithDepositPermit(permit *PermitSignature) DepositOption {
	return func(o *DepositOptions) { o.Permit = permit }
}

// PlaceDeposit locks a security deposit with a provider.
func (w *Wallet) PlaceDeposit(ctx context.Context, provider string, amount decimal.Decimal, expires time.Duration, opts ...DepositOption) (*Deposit, error) {
	if err := validateAddress(provider); err != nil {
		return nil, err
	}
	if err := validateAmount(amount); err != nil {
		return nil, err
	}
	cfg := &DepositOptions{}
	for _, o := range opts {
		o(cfg)
	}
	body := map[string]any{
		"chain":    w.chain,
		"provider": provider,
		"amount":   amount.InexactFloat64(),
		"expiry":   int(time.Now().Unix()) + int(expires.Seconds()),
	}
	if cfg.Permit != nil {
		body["permit"] = cfg.Permit
	}
	var deposit Deposit
	if err := w.http.post(ctx, "/api/v0/deposits", body, &deposit); err != nil {
		return nil, err
	}
	return &deposit, nil
}

// LockDeposit locks a security deposit with a beneficiary.
// Deprecated: Use PlaceDeposit instead.
func (w *Wallet) LockDeposit(ctx context.Context, beneficiary string, amount decimal.Decimal, expiresIn time.Duration) (*Deposit, error) {
	return w.PlaceDeposit(ctx, beneficiary, amount, expiresIn)
}

// ReturnDeposit returns a deposit to the payer.
func (w *Wallet) ReturnDeposit(ctx context.Context, depositID string) (*Transaction, error) {
	var tx Transaction
	if err := w.http.post(ctx, "/api/v0/deposits/"+depositID+"/return", map[string]any{}, &tx); err != nil {
		return nil, err
	}
	return &tx, nil
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

// ─── Contracts ────────────────────────────────────────────────────────────────

// GetContracts returns on-chain contract addresses (cached after first call).
func (w *Wallet) GetContracts(ctx context.Context) (*ContractAddresses, error) {
	if w.contractsCache != nil {
		return w.contractsCache, nil
	}
	var contracts ContractAddresses
	if err := w.http.get(ctx, "/api/v0/contracts", &contracts); err != nil {
		return nil, err
	}
	w.contractsCache = &contracts
	return w.contractsCache, nil
}

// ─── Mint ─────────────────────────────────────────────────────────────────────

// Mint mints testnet USDC. Returns the tx hash and new balance.
func (w *Wallet) Mint(ctx context.Context, amount float64) (*MintResponse, error) {
	var resp MintResponse
	if err := w.http.post(ctx, "/api/v0/mint", map[string]any{
		"wallet": w.Address(),
		"amount": amount,
	}, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

// ─── Testnet ──────────────────────────────────────────────────────────────────

// FaucetResponse is returned by RequestTestnetFunds.
type FaucetResponse struct {
	TxHash    string          `json:"tx_hash"`
	Amount    decimal.Decimal `json:"amount"` // bigdecimal serializes as JSON string on the server side
	Recipient string          `json:"recipient"`
}

// RequestTestnetFunds requests test USDC from the testnet faucet.
// Only available when connected to a testnet.
func (w *Wallet) RequestTestnetFunds(ctx context.Context) (*FaucetResponse, error) {
	var resp FaucetResponse
	if err := w.http.post(ctx, "/api/v0/faucet", map[string]any{"wallet": w.Address()}, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

// ─── One-time operator links ──────────────────────────────────────────────────

// CreateFundLink generates a one-time URL for the operator to fund this wallet.
func (w *Wallet) CreateFundLink(ctx context.Context) (*LinkResponse, error) {
	var lr LinkResponse
	if err := w.http.post(ctx, "/api/v0/links/fund", map[string]any{}, &lr); err != nil {
		return nil, err
	}
	return &lr, nil
}

// CreateWithdrawLink generates a one-time URL for the operator to withdraw funds.
func (w *Wallet) CreateWithdrawLink(ctx context.Context) (*LinkResponse, error) {
	var lr LinkResponse
	if err := w.http.post(ctx, "/api/v0/links/withdraw", map[string]any{}, &lr); err != nil {
		return nil, err
	}
	return &lr, nil
}

// ─── Webhooks ─────────────────────────────────────────────────────────────────

// RegisterWebhook registers a webhook endpoint to receive real-time event notifications.
// events must contain at least one valid event type (e.g. "payment.sent", "escrow.funded").
func (w *Wallet) RegisterWebhook(ctx context.Context, url string, events []string, chains ...string) (*Webhook, error) {
	body := map[string]any{"url": url, "events": events}
	if len(chains) > 0 {
		body["chains"] = chains
	}
	var wh Webhook
	if err := w.http.post(ctx, "/api/v0/webhooks", body, &wh); err != nil {
		return nil, err
	}
	return &wh, nil
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

