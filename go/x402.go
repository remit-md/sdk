package remitmd

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"strings"
)

// X402Paywall gates HTTP endpoints behind x402 micropayments.
//
// It generates PAYMENT-REQUIRED headers for 402 responses and verifies
// incoming PAYMENT-SIGNATURE headers by calling the remit.md facilitator.
//
// Usage:
//
//	paywall, err := remitmd.NewX402Paywall(remitmd.PaywallOptions{
//	    WalletAddress:    "0xYourProviderWallet",
//	    AmountUsdc:       0.001,
//	    Network:          "eip155:84532",
//	    Asset:            "0x2d846325766921935f37d5b4478196d3ef93707c",
//	    FacilitatorToken: os.Getenv("REMITMD_TOKEN"),
//	})
//
//	http.Handle("/v1/data", paywall.Middleware()(yourHandler))
type X402Paywall struct {
	walletAddress    string
	amountBaseUnits  string
	network          string
	asset            string
	facilitatorURL   string
	facilitatorToken string
	maxTimeoutSecs   int
	resource         string
	description      string
	mimeType         string
	httpClient       *http.Client
}

// PaywallOptions configures an [X402Paywall].
type PaywallOptions struct {
	// WalletAddress is the provider's checksummed Ethereum address (payTo).
	WalletAddress string
	// AmountUsdc is the price per request in USDC (e.g. 0.001).
	AmountUsdc float64
	// Network is the CAIP-2 network string (e.g. "eip155:84532" for Base Sepolia).
	Network string
	// Asset is the USDC contract address on the target network.
	Asset string
	// FacilitatorURL is the base URL of the remit.md facilitator (default: "https://remit.md").
	FacilitatorURL string
	// FacilitatorToken is the Bearer JWT for /api/v1/x402/verify calls.
	FacilitatorToken string
	// MaxTimeoutSeconds is how long the payment authorization is valid (default: 60).
	MaxTimeoutSeconds int
	// Resource is the V2 URL or path of the resource being protected (e.g. "/v1/data").
	Resource string
	// Description is the V2 human-readable description of what the payment is for.
	Description string
	// MimeType is the V2 MIME type of the resource (e.g. "application/json").
	MimeType string
}

// NewX402Paywall creates an [X402Paywall] from the given options.
func NewX402Paywall(opts PaywallOptions) (*X402Paywall, error) {
	if opts.WalletAddress == "" {
		return nil, fmt.Errorf("remitmd: WalletAddress is required")
	}
	if opts.AmountUsdc <= 0 {
		return nil, fmt.Errorf("remitmd: AmountUsdc must be positive")
	}
	if opts.Network == "" {
		return nil, fmt.Errorf("remitmd: Network is required")
	}
	if opts.Asset == "" {
		return nil, fmt.Errorf("remitmd: Asset is required")
	}

	baseUnits := int64(math.Round(opts.AmountUsdc * 1_000_000))
	facilitatorURL := opts.FacilitatorURL
	if facilitatorURL == "" {
		facilitatorURL = "https://remit.md"
	}
	facilitatorURL = strings.TrimRight(facilitatorURL, "/")

	maxTimeout := opts.MaxTimeoutSeconds
	if maxTimeout <= 0 {
		maxTimeout = 60
	}

	return &X402Paywall{
		walletAddress:    opts.WalletAddress,
		amountBaseUnits:  fmt.Sprintf("%d", baseUnits),
		network:          opts.Network,
		asset:            opts.Asset,
		facilitatorURL:   facilitatorURL,
		facilitatorToken: opts.FacilitatorToken,
		maxTimeoutSecs:   maxTimeout,
		resource:         opts.Resource,
		description:      opts.Description,
		mimeType:         opts.MimeType,
		httpClient:       &http.Client{Timeout: 10_000_000_000}, // 10s
	}, nil
}

// PaymentRequiredHeader returns the base64-encoded JSON PAYMENT-REQUIRED header value.
func (p *X402Paywall) PaymentRequiredHeader() string {
	payload := map[string]any{
		"scheme":            "exact",
		"network":           p.network,
		"amount":            p.amountBaseUnits,
		"asset":             p.asset,
		"payTo":             p.walletAddress,
		"maxTimeoutSeconds": p.maxTimeoutSecs,
	}
	if p.resource != "" {
		payload["resource"] = p.resource
	}
	if p.description != "" {
		payload["description"] = p.description
	}
	if p.mimeType != "" {
		payload["mimeType"] = p.mimeType
	}
	b, _ := json.Marshal(payload)
	return base64.StdEncoding.EncodeToString(b)
}

// CheckResult holds the outcome of [X402Paywall.Check].
type CheckResult struct {
	IsValid       bool
	InvalidReason string // non-empty when IsValid is false and a signature was present
}

// Check verifies a PAYMENT-SIGNATURE header value against the facilitator.
//
// sig is the raw header value (base64 JSON). An empty string returns
// CheckResult{IsValid: false} without calling the facilitator.
func (p *X402Paywall) Check(ctx context.Context, sig string) (CheckResult, error) {
	if sig == "" {
		return CheckResult{IsValid: false}, nil
	}

	sigBytes, err := base64.StdEncoding.DecodeString(sig)
	if err != nil {
		return CheckResult{IsValid: false, InvalidReason: "INVALID_PAYLOAD"}, nil
	}

	var paymentPayload any
	if err := json.Unmarshal(sigBytes, &paymentPayload); err != nil {
		return CheckResult{IsValid: false, InvalidReason: "INVALID_PAYLOAD"}, nil
	}

	body := map[string]any{
		"paymentPayload": paymentPayload,
		"paymentRequired": map[string]any{
			"scheme":            "exact",
			"network":           p.network,
			"amount":            p.amountBaseUnits,
			"asset":             p.asset,
			"payTo":             p.walletAddress,
			"maxTimeoutSeconds": p.maxTimeoutSecs,
		},
	}
	bodyBytes, err := json.Marshal(body)
	if err != nil {
		return CheckResult{IsValid: false, InvalidReason: "FACILITATOR_ERROR"}, nil
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		p.facilitatorURL+"/api/v1/x402/verify",
		bytes.NewReader(bodyBytes),
	)
	if err != nil {
		return CheckResult{IsValid: false, InvalidReason: "FACILITATOR_ERROR"}, nil
	}
	req.Header.Set("Content-Type", "application/json")
	if p.facilitatorToken != "" {
		req.Header.Set("Authorization", "Bearer "+p.facilitatorToken)
	}

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return CheckResult{IsValid: false, InvalidReason: "FACILITATOR_ERROR"}, nil
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return CheckResult{IsValid: false, InvalidReason: "FACILITATOR_ERROR"}, nil
	}

	respBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return CheckResult{IsValid: false, InvalidReason: "FACILITATOR_ERROR"}, nil
	}

	var data struct {
		IsValid       bool   `json:"isValid"`
		InvalidReason string `json:"invalidReason"`
	}
	if err := json.Unmarshal(respBytes, &data); err != nil {
		return CheckResult{IsValid: false, InvalidReason: "FACILITATOR_ERROR"}, nil
	}

	return CheckResult{IsValid: data.IsValid, InvalidReason: data.InvalidReason}, nil
}

// Middleware returns an HTTP middleware that enforces x402 payment.
//
// Unauthenticated or invalid requests receive a 402 response with a
// PAYMENT-REQUIRED header. Valid requests are forwarded to next.
//
// Usage:
//
//	mux.Handle("/v1/data", paywall.Middleware()(http.HandlerFunc(myHandler)))
func (p *X402Paywall) Middleware() func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			sig := r.Header.Get("payment-signature")
			if sig == "" {
				sig = r.Header.Get("PAYMENT-SIGNATURE")
			}
			result, _ := p.Check(r.Context(), sig)
			if !result.IsValid {
				w.Header().Set("PAYMENT-REQUIRED", p.PaymentRequiredHeader())
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusPaymentRequired)
				body := `{"error":"Payment required"`
				if result.InvalidReason != "" {
					body += `,"invalidReason":` + fmt.Sprintf("%q", result.InvalidReason)
				}
				body += "}"
				_, _ = w.Write([]byte(body))
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
