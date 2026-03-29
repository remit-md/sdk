package remitmd

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"time"
)

// AllowanceExceededError is raised when an x402 payment amount exceeds the
// configured auto-pay limit.
type AllowanceExceededError struct {
	AmountUsdc float64
	LimitUsdc  float64
}

func (e *AllowanceExceededError) Error() string {
	return fmt.Sprintf("x402 payment %.6f USDC exceeds auto-pay limit %.6f USDC", e.AmountUsdc, e.LimitUsdc)
}

// X402Response wraps the HTTP response and the decoded PAYMENT-REQUIRED header
// from the last 402 interaction.
type X402Response struct {
	Response    *http.Response
	LastPayment *PaymentRequired
}

// PaymentRequired is the decoded shape of the PAYMENT-REQUIRED header (V2).
type PaymentRequired struct {
	Scheme            string `json:"scheme"`
	Network           string `json:"network"`
	Amount            string `json:"amount"`
	Asset             string `json:"asset"`
	PayTo             string `json:"payTo"`
	MaxTimeoutSeconds int    `json:"maxTimeoutSeconds,omitempty"`
	Resource          string `json:"resource,omitempty"`
	Description       string `json:"description,omitempty"`
	MimeType          string `json:"mimeType,omitempty"`
}

// X402Client is a consumer-side HTTP client that auto-pays x402 Payment Required
// responses by calling the server's /x402/prepare endpoint.
type X402Client struct {
	wallet         *Wallet
	MaxAutoPayUsdc float64
	httpClient     *http.Client
}

// NewX402Client creates an X402Client from a Wallet.
// maxAutoPayUsdc sets the maximum USDC to auto-pay per request (default: 0.10).
func NewX402Client(wallet *Wallet, maxAutoPayUsdc ...float64) *X402Client {
	limit := 0.10
	if len(maxAutoPayUsdc) > 0 && maxAutoPayUsdc[0] > 0 {
		limit = maxAutoPayUsdc[0]
	}
	return &X402Client{
		wallet:         wallet,
		MaxAutoPayUsdc: limit,
		httpClient:     &http.Client{Timeout: 30 * time.Second},
	}
}

// Fetch makes a GET request to the given URL. If a 402 Payment Required is
// returned, it calls /x402/prepare, signs the hash, and retries with a
// PAYMENT-SIGNATURE header.
func (c *X402Client) Fetch(ctx context.Context, url string) (*X402Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("x402: create request: %w", err)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("x402: request failed: %w", err)
	}

	if resp.StatusCode != http.StatusPaymentRequired {
		return &X402Response{Response: resp}, nil
	}

	return c.handle402(ctx, url, resp)
}

func (c *X402Client) handle402(ctx context.Context, url string, resp *http.Response) (*X402Response, error) {
	defer resp.Body.Close()

	// 1. Decode PAYMENT-REQUIRED header (case-insensitive).
	raw := resp.Header.Get("payment-required")
	if raw == "" {
		raw = resp.Header.Get("PAYMENT-REQUIRED")
	}
	if raw == "" {
		return nil, fmt.Errorf("x402: 402 response missing PAYMENT-REQUIRED header")
	}

	decoded, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return nil, fmt.Errorf("x402: decode PAYMENT-REQUIRED: %w", err)
	}

	var required PaymentRequired
	if err := json.Unmarshal(decoded, &required); err != nil {
		return nil, fmt.Errorf("x402: parse PAYMENT-REQUIRED: %w", err)
	}

	// 2. Only "exact" scheme is supported.
	if required.Scheme != "exact" {
		return nil, fmt.Errorf("x402: unsupported scheme: %s", required.Scheme)
	}

	// 3. Check auto-pay limit.
	amountBaseUnits := new(big.Int)
	amountBaseUnits.SetString(required.Amount, 10)
	amountUsdc := float64(amountBaseUnits.Int64()) / 1_000_000.0
	if amountUsdc > c.MaxAutoPayUsdc {
		return nil, &AllowanceExceededError{AmountUsdc: amountUsdc, LimitUsdc: c.MaxAutoPayUsdc}
	}

	// 4. Call /x402/prepare to get the hash + authorization fields.
	var prepareData struct {
		Hash        string `json:"hash"`
		From        string `json:"from"`
		To          string `json:"to"`
		Value       string `json:"value"`
		ValidAfter  string `json:"valid_after"`
		ValidBefore string `json:"valid_before"`
		Nonce       string `json:"nonce"`
	}
	if err := c.wallet.http.post(ctx, "/api/v1/x402/prepare", map[string]any{
		"payment_required": raw,
		"payer":            c.wallet.Address(),
	}, &prepareData); err != nil {
		return nil, fmt.Errorf("x402: /x402/prepare failed: %w", err)
	}

	// 5. Sign the hash.
	hashHex := strings.TrimPrefix(prepareData.Hash, "0x")
	hashBytes, err := hex.DecodeString(hashHex)
	if err != nil {
		return nil, fmt.Errorf("x402: invalid hash hex: %w", err)
	}
	signature, err := c.wallet.signer.SignHash(hashBytes)
	if err != nil {
		return nil, fmt.Errorf("x402: sign: %w", err)
	}

	// 6. Build PAYMENT-SIGNATURE JSON payload.
	paymentPayload := map[string]any{
		"scheme":      required.Scheme,
		"network":     required.Network,
		"x402Version": 1,
		"payload": map[string]any{
			"signature": signature,
			"authorization": map[string]any{
				"from":        prepareData.From,
				"to":          prepareData.To,
				"value":       prepareData.Value,
				"validAfter":  prepareData.ValidAfter,
				"validBefore": prepareData.ValidBefore,
				"nonce":       prepareData.Nonce,
			},
		},
	}

	payloadJSON, err := json.Marshal(paymentPayload)
	if err != nil {
		return nil, fmt.Errorf("x402: marshal payment payload: %w", err)
	}
	paymentHeader := base64.StdEncoding.EncodeToString(payloadJSON)

	// 7. Retry with PAYMENT-SIGNATURE header.
	retryReq, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("x402: create retry request: %w", err)
	}
	retryReq.Header.Set("PAYMENT-SIGNATURE", paymentHeader)

	retryResp, err := c.httpClient.Do(retryReq)
	if err != nil {
		return nil, fmt.Errorf("x402: retry request failed: %w", err)
	}

	return &X402Response{
		Response:    retryResp,
		LastPayment: &required,
	}, nil
}
