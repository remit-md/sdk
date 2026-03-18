package remitmd

import (
	"time"

	"github.com/shopspring/decimal"
)

// ChainID identifies an EVM chain supported by remit.md.
type ChainID int

const (
	ChainBase    ChainID = 8453
	ChainBaseSep ChainID = 84532 // Base Sepolia testnet
)

// Status values for payment primitives.
type (
	InvoiceStatus string
	EscrowStatus  string
	TabStatus     string
	StreamStatus  string
	BountyStatus  string
	DepositStatus string
)

const (
	InvoiceStatusPending   InvoiceStatus = "pending"
	InvoiceStatusFunded    InvoiceStatus = "funded"
	InvoiceStatusReleased  InvoiceStatus = "released"
	InvoiceStatusCancelled InvoiceStatus = "cancelled"
	InvoiceStatusExpired   InvoiceStatus = "expired"

	EscrowStatusPending   EscrowStatus = "pending"
	EscrowStatusFunded    EscrowStatus = "funded"
	EscrowStatusReleased  EscrowStatus = "released"
	EscrowStatusCancelled EscrowStatus = "cancelled"
	EscrowStatusExpired   EscrowStatus = "expired"

	TabStatusOpen   TabStatus = "open"
	TabStatusClosed TabStatus = "closed"
	TabStatusSettled TabStatus = "settled"

	StreamStatusActive   StreamStatus = "active"
	StreamStatusPaused   StreamStatus = "paused"
	StreamStatusEnded    StreamStatus = "ended"
	StreamStatusCancelled StreamStatus = "cancelled"

	BountyStatusOpen       BountyStatus = "open"
	BountyStatusAwarded    BountyStatus = "awarded"
	BountyStatusExpired    BountyStatus = "expired"
	BountyStatusReclaimed  BountyStatus = "reclaimed"

	DepositStatusLocked    DepositStatus = "locked"
	DepositStatusReturned  DepositStatus = "returned"
	DepositStatusForfeited DepositStatus = "forfeited"
)

// PermitSignature holds an EIP-2612 permit signature for gasless USDC approval.
type PermitSignature struct {
	Value    int    `json:"value"`
	Deadline int    `json:"deadline"`
	V        int    `json:"v"`
	R        string `json:"r"`
	S        string `json:"s"`
}

// ContractAddresses holds on-chain contract addresses returned by GET /api/v0/contracts.
type ContractAddresses struct {
	ChainID       int    `json:"chain_id"`
	USDC          string `json:"usdc"`
	Router        string `json:"router"`
	Escrow        string `json:"escrow"`
	Tab           string `json:"tab"`
	Stream        string `json:"stream"`
	Bounty        string `json:"bounty"`
	Deposit       string `json:"deposit"`
	FeeCalculator string `json:"fee_calculator"`
	KeyRegistry   string `json:"key_registry"`
	Arbitration   string `json:"arbitration"`
}

// MintResponse is returned by Mint.
type MintResponse struct {
	TxHash  string `json:"tx_hash"`
	Balance string `json:"balance"`
}

// Transaction is the result of any payment operation.
type Transaction struct {
	ID          string          `json:"id"`
	TxHash      string          `json:"tx_hash"`
	From        string          `json:"from"`
	To          string          `json:"to"`
	Amount      decimal.Decimal `json:"amount"`
	Fee         decimal.Decimal `json:"fee"`
	Memo        string          `json:"memo"`
	ChainID     ChainID         `json:"chain_id"`
	BlockNumber uint64          `json:"block_number"`
	CreatedAt   time.Time       `json:"created_at"`
}

// Balance represents a wallet's current USDC balance.
type Balance struct {
	USDC      decimal.Decimal `json:"usdc"`
	Address   string          `json:"address"`
	ChainID   ChainID         `json:"chain_id"`
	UpdatedAt time.Time       `json:"updated_at"`
}

// Reputation is an agent's on-chain payment reputation score.
type Reputation struct {
	Address          string          `json:"address"`
	Score            int             `json:"score"`       // 0-1000
	TotalPaid        decimal.Decimal `json:"total_paid"`
	TotalReceived    decimal.Decimal `json:"total_received"`
	TransactionCount int             `json:"transaction_count"`
	MemberSince      time.Time       `json:"member_since"`
}

// Milestone is a partial payment condition within an Escrow.
type Milestone struct {
	ID          string          `json:"id,omitempty"`
	Description string          `json:"description"`
	Amount      decimal.Decimal `json:"amount"`
	Released    bool            `json:"released"`
}

// Split distributes an escrow payment among multiple recipients.
type Split struct {
	Recipient string          `json:"recipient"`
	Amount    decimal.Decimal `json:"amount"`
}

// Escrow holds funds until conditions are met.
// Field names match the server's models::escrow::Escrow struct (snake_case JSON).
type Escrow struct {
	InvoiceID    string          `json:"invoice_id"`
	Chain        string          `json:"chain"`
	TxHash       string          `json:"tx_hash"`
	Status       EscrowStatus    `json:"status"`
	Payer        string          `json:"payer"`
	Payee        string          `json:"payee"`
	Amount       decimal.Decimal `json:"amount"`
	Fee          decimal.Decimal `json:"fee"`
	Timeout      string          `json:"timeout,omitempty"`
	ClaimStarted bool            `json:"claim_started"`
	CreatedAt    string          `json:"created_at"`
	UpdatedAt    string          `json:"updated_at,omitempty"`
}

// Tab is a metered payment channel (payer pre-funds, provider charges per call).
// Field names match the server's models::tab::Tab struct (snake_case JSON).
type Tab struct {
	ID            string          `json:"id"`
	Chain         string          `json:"chain"`
	Payer         string          `json:"payer"`
	Provider      string          `json:"provider"`
	LimitAmount   decimal.Decimal `json:"limit_amount"`
	PerUnit       decimal.Decimal `json:"per_unit"`
	TotalCharged  decimal.Decimal `json:"total_charged"`
	CallCount     int             `json:"call_count"`
	Status        TabStatus       `json:"status"`
	Expiry        string          `json:"expiry"`
	TxHash        string          `json:"tx_hash"`
	ClosedTxHash  string          `json:"closed_tx_hash,omitempty"`
	CreatedAt     string          `json:"created_at"`
	UpdatedAt     string          `json:"updated_at,omitempty"`
}

// TabDebit records a single charge against a Tab.
type TabDebit struct {
	TabID     string          `json:"tab_id"`
	Amount    decimal.Decimal `json:"amount"`
	Memo      string          `json:"memo"`
	Sequence  uint64          `json:"sequence"`
	Signature string          `json:"signature"`
}

// Stream is a time-based payment flow (pay-per-second).
type Stream struct {
	ID          string          `json:"id"`
	Sender      string          `json:"sender"`
	Recipient   string          `json:"recipient"`
	RatePerSec  decimal.Decimal `json:"rate_per_sec"`
	Deposited   decimal.Decimal `json:"deposited"`
	Withdrawn   decimal.Decimal `json:"withdrawn"`
	Status      StreamStatus    `json:"status"`
	StartedAt   time.Time       `json:"started_at"`
	EndsAt      *time.Time      `json:"ends_at,omitempty"`
}

// Bounty is a task with a USDC reward for completion.
type Bounty struct {
	ID          string          `json:"id"`
	Poster      string          `json:"poster"`
	Award       decimal.Decimal `json:"award"`
	Description string          `json:"description"`
	Status      BountyStatus    `json:"status"`
	Winner      string          `json:"winner,omitempty"`
	ExpiresAt   *time.Time      `json:"expires_at,omitempty"`
	CreatedAt   time.Time       `json:"created_at"`
}

// Deposit is a security deposit held as collateral.
type Deposit struct {
	ID          string          `json:"id"`
	Depositor   string          `json:"depositor"`
	Beneficiary string          `json:"beneficiary"`
	Amount      decimal.Decimal `json:"amount"`
	Status      DepositStatus   `json:"status"`
	ExpiresAt   *time.Time      `json:"expires_at,omitempty"`
	CreatedAt   time.Time       `json:"created_at"`
}

// Intent represents a proposed payment awaiting negotiation.
type Intent struct {
	ID          string          `json:"id"`
	From        string          `json:"from"`
	To          string          `json:"to"`
	Amount      decimal.Decimal `json:"amount"`
	Type        string          `json:"type"` // "direct", "escrow", "tab", etc.
	ExpiresAt   time.Time       `json:"expires_at"`
	CreatedAt   time.Time       `json:"created_at"`
}

// SpendingSummary provides spending analytics for a wallet.
type SpendingSummary struct {
	Address      string          `json:"address"`
	Period       string          `json:"period"`
	TotalSpent   decimal.Decimal `json:"total_spent"`
	TotalFees    decimal.Decimal `json:"total_fees"`
	TxCount      int             `json:"tx_count"`
	TopRecipients []struct {
		Address string          `json:"address"`
		Amount  decimal.Decimal `json:"amount"`
	} `json:"top_recipients"`
}

// Budget shows remaining spending capacity under operator-set limits.
type Budget struct {
	DailyLimit       decimal.Decimal `json:"daily_limit"`
	DailyUsed        decimal.Decimal `json:"daily_used"`
	DailyRemaining   decimal.Decimal `json:"daily_remaining"`
	MonthlyLimit     decimal.Decimal `json:"monthly_limit"`
	MonthlyUsed      decimal.Decimal `json:"monthly_used"`
	MonthlyRemaining decimal.Decimal `json:"monthly_remaining"`
	PerTxLimit       decimal.Decimal `json:"per_tx_limit"`
}

// LinkResponse is a one-time operator link for funding or withdrawing.
type LinkResponse struct {
	URL           string `json:"url"`
	Token         string `json:"token"`
	ExpiresAt     string `json:"expires_at"`
	WalletAddress string `json:"wallet_address"`
}

// TransactionList is a paginated list of transactions.
type TransactionList struct {
	Items      []Transaction `json:"items"`
	Total      int           `json:"total"`
	Page       int           `json:"page"`
	PerPage    int           `json:"per_page"`
	HasMore    bool          `json:"has_more"`
}

// Webhook is a registered webhook endpoint.
type Webhook struct {
	ID        string    `json:"id"`
	Wallet    string    `json:"wallet"`
	URL       string    `json:"url"`
	Events    []string  `json:"events"`
	Chains    []string  `json:"chains"`
	Active    bool      `json:"active"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}
