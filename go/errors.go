package remitmd

import "fmt"

const docBase = "https://remit.md/docs/errors#"

// RemitError is the structured error type returned by all SDK methods.
// Every error has a machine-readable Code, actionable Message, and a
// documentation link pointing to the specific error's remediation guide.
type RemitError struct {
	// Code is a stable, machine-readable error identifier (e.g., "INVALID_ADDRESS").
	Code string
	// Message is a human/agent-readable explanation with guidance on how to fix it.
	Message string
	// DocURL links directly to the documentation for this error code.
	DocURL string
	// Context contains the offending values that caused the error.
	Context map[string]any
}

func (e *RemitError) Error() string {
	return fmt.Sprintf("remitmd: %s — %s (see: %s)", e.Code, e.Message, e.DocURL)
}

func remitErr(code, message string, ctx map[string]any) *RemitError {
	return &RemitError{
		Code:    code,
		Message: message,
		DocURL:  docBase + code,
		Context: ctx,
	}
}

// Sentinel error codes — stable across SDK versions.
const (
	ErrCodeInvalidAddress      = "INVALID_ADDRESS"
	ErrCodeInvalidAmount       = "INVALID_AMOUNT"
	ErrCodeInsufficientFunds   = "INSUFFICIENT_FUNDS"
	ErrCodeEscrowNotFound      = "ESCROW_NOT_FOUND"
	ErrCodeEscrowAlreadyFunded = "ESCROW_ALREADY_FUNDED"
	ErrCodeEscrowNotFunded     = "ESCROW_NOT_FUNDED"
	ErrCodeEscrowExpired       = "ESCROW_EXPIRED"
	ErrCodeTabNotFound         = "TAB_NOT_FOUND"
	ErrCodeTabClosed           = "TAB_CLOSED"
	ErrCodeTabLimitExceeded    = "TAB_LIMIT_EXCEEDED"
	ErrCodeStreamNotFound      = "STREAM_NOT_FOUND"
	ErrCodeStreamEnded         = "STREAM_ENDED"
	ErrCodeBountyNotFound      = "BOUNTY_NOT_FOUND"
	ErrCodeBountyExpired       = "BOUNTY_EXPIRED"
	ErrCodeDepositNotFound     = "DEPOSIT_NOT_FOUND"
	ErrCodeSpendingLimitHit    = "SPENDING_LIMIT_HIT"
	ErrCodeRateLimited         = "RATE_LIMITED"
	ErrCodeUnauthorized        = "UNAUTHORIZED"
	ErrCodeNetworkError        = "NETWORK_ERROR"
	ErrCodeServerError         = "SERVER_ERROR"
	ErrCodeInvalidSignature    = "INVALID_SIGNATURE"
	ErrCodeChainMismatch       = "CHAIN_MISMATCH"
)
