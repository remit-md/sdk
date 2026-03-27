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
	return fmt.Sprintf("remitmd: %s - %s (see: %s)", e.Code, e.Message, e.DocURL)
}

func remitErr(code, message string, ctx map[string]any) *RemitError {
	return &RemitError{
		Code:    code,
		Message: message,
		DocURL:  docBase + code,
		Context: ctx,
	}
}

// Sentinel error codes - stable across SDK versions.
const (
	ErrCodeInvalidAddress  = "INVALID_ADDRESS"
	ErrCodeInvalidAmount   = "INVALID_AMOUNT"
	ErrCodeServerError     = "SERVER_ERROR"

	// Authentication / authorization (401)
	ErrCodeInvalidSignature = "INVALID_SIGNATURE"
	ErrCodeNonceReused      = "NONCE_REUSED"
	ErrCodeTimestampExpired = "TIMESTAMP_EXPIRED"
	ErrCodeUnauthorized     = "UNAUTHORIZED"

	// Balance (402)
	ErrCodeInsufficientBalance = "INSUFFICIENT_BALANCE"

	// Validation (400)
	ErrCodeBelowMinimum     = "BELOW_MINIMUM"
	ErrCodeInvalidInvoice   = "INVALID_INVOICE"
	ErrCodeSelfPayment      = "SELF_PAYMENT"
	ErrCodeInvalidPaymentType = "INVALID_PAYMENT_TYPE"

	// Conflict (409)
	ErrCodeDuplicateInvoice      = "DUPLICATE_INVOICE"
	ErrCodeEscrowAlreadyFunded   = "ESCROW_ALREADY_FUNDED"
	ErrCodeBountyClaimed         = "BOUNTY_CLAIMED"
	ErrCodeChainMismatch         = "CHAIN_MISMATCH"
	ErrCodeCancelBlockedClaimStart = "CANCEL_BLOCKED_CLAIM_START"
	ErrCodeCancelBlockedEvidence   = "CANCEL_BLOCKED_EVIDENCE"

	// Not found (404)
	ErrCodeEscrowNotFound = "ESCROW_NOT_FOUND"
	ErrCodeTabNotFound    = "TAB_NOT_FOUND"
	ErrCodeStreamNotFound = "STREAM_NOT_FOUND"
	ErrCodeBountyNotFound = "BOUNTY_NOT_FOUND"

	// Expired (410)
	ErrCodeEscrowExpired = "ESCROW_EXPIRED"
	ErrCodeTabExpired    = "TAB_EXPIRED"
	ErrCodeBountyExpired = "BOUNTY_EXPIRED"

	// Unprocessable (422)
	ErrCodeRateExceedsCap   = "RATE_EXCEEDS_CAP"
	ErrCodeBountyMaxAttempts = "BOUNTY_MAX_ATTEMPTS"
	ErrCodeChainUnsupported = "CHAIN_UNSUPPORTED"
	ErrCodeVersionMismatch  = "VERSION_MISMATCH"

	// Tab-specific (402)
	ErrCodeTabDepleted = "TAB_DEPLETED"

	// Rate limit (429)
	ErrCodeRateLimited = "RATE_LIMITED"

	// Network (503)
	ErrCodeNetworkError = "NETWORK_ERROR"
)

// Deprecated: Use ErrCodeInsufficientBalance instead.
const ErrCodeInsufficientFunds = ErrCodeInsufficientBalance
