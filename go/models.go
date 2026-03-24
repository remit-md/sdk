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

	EscrowStatusFunded    EscrowStatus = "funded"
	EscrowStatusActive    EscrowStatus = "active"
	EscrowStatusCompleted EscrowStatus = "completed"
	EscrowStatusDisputed  EscrowStatus = "disputed"
	EscrowStatusCancelled EscrowStatus = "cancelled"
	EscrowStatusTimedOut  EscrowStatus = "timed_out"

	TabStatusOpen     TabStatus = "open"
	TabStatusDepleted TabStatus = "depleted"
	TabStatusClosed   TabStatus = "closed"
	TabStatusExpired  TabStatus = "expired"

	StreamStatusActive     StreamStatus = "active"
	StreamStatusClosed     StreamStatus = "closed"
	StreamStatusTerminated StreamStatus = "terminated"

	BountyStatusOpen      BountyStatus = "open"
	BountyStatusClaimed   BountyStatus = "claimed"
	BountyStatusAwarded   BountyStatus = "awarded"
	BountyStatusExpired   BountyStatus = "expired"
	BountyStatusReclaimed BountyStatus = "reclaimed"

	DepositStatusLocked    DepositStatus = "locked"
	DepositStatusReturned  DepositStatus = "returned"
	DepositStatusForfeited DepositStatus = "forfeited"
)

// PermitSignature holds an EIP-2612 permit signature for gasless USDC approval.
type PermitSignature struct {
	Value    int64  `json:"value"`
	Deadline int64  `json:"deadline"`
	V        int    `json:"v"`
	R        string `json:"r"`
	S        string `json:"s"`
}

// ContractAddresses holds on-chain contract addresses returned by GET /api/v1/contracts.
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
	Relayer       string `json:"relayer,omitempty"`
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
// Deprecated: Use TabCharge instead. Kept for backward compatibility.
type TabDebit struct {
	TabID     string          `json:"tab_id"`
	Amount    decimal.Decimal `json:"amount"`
	Memo      string          `json:"memo"`
	Sequence  uint64          `json:"sequence"`
	Signature string          `json:"signature"`
}

// TabCharge records a single charge against a Tab (new server model).
// Amount and Cumulative are strings because the server returns BigDecimal values.
type TabCharge struct {
	ID          int    `json:"id"`
	TabID       string `json:"tab_id"`
	Amount      string `json:"amount"`
	Cumulative  string `json:"cumulative"`
	CallCount   int    `json:"call_count"`
	ProviderSig string `json:"provider_sig"`
	ChargedAt   string `json:"charged_at"`
}

// Stream is a time-based payment flow (pay-per-second).
// Field names match the server's models::stream::Stream struct (snake_case JSON).
// BigDecimal fields are serialized as JSON strings by the server.
type Stream struct {
	ID            string `json:"id"`
	Chain         string `json:"chain"`
	Payer         string `json:"payer"`
	Payee         string `json:"payee"`
	RatePerSecond string `json:"rate_per_second"`
	MaxTotal      string `json:"max_total"`
	Withdrawn     string `json:"withdrawn"`
	Status        string `json:"status"`
	StartedAt     string `json:"started_at"`
	ClosedAt      string `json:"closed_at,omitempty"`
	TxHash        string `json:"tx_hash"`
	UpdatedAt     string `json:"updated_at"`
}

// Bounty is a task with a USDC reward for completion.
// Field names match the server's models::bounty::Bounty struct (snake_case JSON).
type Bounty struct {
	ID              string `json:"id"`
	Chain           string `json:"chain"`
	Poster          string `json:"poster"`
	Amount          string `json:"amount"`
	TaskDescription string `json:"task_description"`
	Deadline        int64  `json:"deadline,omitempty"`
	MaxAttempts     int    `json:"max_attempts,omitempty"`
	Status          string `json:"status"`
	Winner          string `json:"winner,omitempty"`
	TxHash          string `json:"tx_hash,omitempty"`
	CreatedAt       string `json:"created_at"`
	UpdatedAt       string `json:"updated_at,omitempty"`
}

// BountySubmission records a submission against a Bounty.
type BountySubmission struct {
	ID           int    `json:"id"`
	BountyID     string `json:"bounty_id"`
	Submitter    string `json:"submitter"`
	EvidenceHash string `json:"evidence_hash"`
	Status       string `json:"status"`
	SubmittedAt  string `json:"submitted_at"`
}

// Deposit is a security deposit held as collateral.
// Field names match the server's models::deposit::Deposit struct (snake_case JSON).
type Deposit struct {
	ID        string `json:"id"`
	Chain     string `json:"chain"`
	Payer     string `json:"payer"`
	Provider  string `json:"provider"`
	Amount    string `json:"amount"`
	Status    string `json:"status"`
	Expiry    string `json:"expiry"`
	TxHash    string `json:"tx_hash,omitempty"`
	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at,omitempty"`
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

// WalletStatus is returned by GET /api/v1/status/{address}.
type WalletStatus struct {
	Wallet        string `json:"wallet"`
	Balance       string `json:"balance"`
	MonthlyVolume string `json:"monthly_volume"`
	Tier          string `json:"tier"`
	FeeRateBps    int    `json:"fee_rate_bps"`
	ActiveEscrows int    `json:"active_escrows"`
	ActiveTabs    int    `json:"active_tabs"`
	ActiveStreams  int    `json:"active_streams"`
	PermitNonce   *int   `json:"permit_nonce"`
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
