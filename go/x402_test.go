package remitmd_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	remitmd "github.com/remit-md/sdk/go"
)

const (
	_testWallet  = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
	_testNetwork = "eip155:84532"
	_testAsset   = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
)

func makePaywall(t *testing.T, opts ...func(*remitmd.PaywallOptions)) *remitmd.X402Paywall {
	t.Helper()
	o := remitmd.PaywallOptions{
		WalletAddress: _testWallet,
		AmountUsdc:    0.001,
		Network:       _testNetwork,
		Asset:         _testAsset,
	}
	for _, fn := range opts {
		fn(&o)
	}
	pw, err := remitmd.NewX402Paywall(o)
	if err != nil {
		t.Fatalf("NewX402Paywall: %v", err)
	}
	return pw
}

func decodeHeader(t *testing.T, raw string) map[string]any {
	t.Helper()
	b, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		t.Fatalf("base64 decode: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("json unmarshal: %v", err)
	}
	return m
}

func makeDummySig() string {
	payload := map[string]any{
		"scheme":      "exact",
		"network":     _testNetwork,
		"x402Version": 1,
		"payload": map[string]any{
			"signature": "0xdeadbeef",
			"authorization": map[string]any{
				"from":        "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
				"to":          _testWallet,
				"value":       "1000",
				"validAfter":  "0",
				"validBefore": "9999999999",
				"nonce":       "0xabcdef1234567890",
			},
		},
	}
	b, _ := json.Marshal(payload)
	return base64.StdEncoding.EncodeToString(b)
}

// ─── Construction ─────────────────────────────────────────────────────────────

func TestNewX402Paywall_Validation(t *testing.T) {
	tests := []struct {
		name    string
		opts    remitmd.PaywallOptions
		wantErr bool
	}{
		{
			name: "valid",
			opts: remitmd.PaywallOptions{WalletAddress: _testWallet, AmountUsdc: 0.001, Network: _testNetwork, Asset: _testAsset},
		},
		{
			name:    "missing wallet",
			opts:    remitmd.PaywallOptions{AmountUsdc: 0.001, Network: _testNetwork, Asset: _testAsset},
			wantErr: true,
		},
		{
			name:    "zero amount",
			opts:    remitmd.PaywallOptions{WalletAddress: _testWallet, AmountUsdc: 0, Network: _testNetwork, Asset: _testAsset},
			wantErr: true,
		},
		{
			name:    "missing network",
			opts:    remitmd.PaywallOptions{WalletAddress: _testWallet, AmountUsdc: 0.001, Asset: _testAsset},
			wantErr: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := remitmd.NewX402Paywall(tc.opts)
			if tc.wantErr && err == nil {
				t.Error("expected error, got nil")
			}
			if !tc.wantErr && err != nil {
				t.Errorf("unexpected error: %v", err)
			}
		})
	}
}

// ─── PaymentRequiredHeader ────────────────────────────────────────────────────

func TestPaymentRequiredHeader_Structure(t *testing.T) {
	pw := makePaywall(t)
	raw := pw.PaymentRequiredHeader()
	m := decodeHeader(t, raw)

	if m["scheme"] != "exact" {
		t.Errorf("scheme = %v, want exact", m["scheme"])
	}
	if m["network"] != _testNetwork {
		t.Errorf("network = %v, want %v", m["network"], _testNetwork)
	}
	if m["amount"] != "1000" { // 0.001 USDC * 1_000_000
		t.Errorf("amount = %v, want 1000", m["amount"])
	}
	if m["payTo"] != _testWallet {
		t.Errorf("payTo = %v, want %v", m["payTo"], _testWallet)
	}
}

func TestPaymentRequiredHeader_V2Fields(t *testing.T) {
	pw := makePaywall(t, func(o *remitmd.PaywallOptions) {
		o.Resource = "/v1/data"
		o.Description = "Market data feed"
		o.MimeType = "application/json"
	})
	m := decodeHeader(t, pw.PaymentRequiredHeader())

	if m["resource"] != "/v1/data" {
		t.Errorf("resource = %v, want /v1/data", m["resource"])
	}
	if m["description"] != "Market data feed" {
		t.Errorf("description = %v", m["description"])
	}
	if m["mimeType"] != "application/json" {
		t.Errorf("mimeType = %v", m["mimeType"])
	}
}

func TestPaymentRequiredHeader_V2Fields_Absent(t *testing.T) {
	pw := makePaywall(t)
	m := decodeHeader(t, pw.PaymentRequiredHeader())

	if _, ok := m["resource"]; ok {
		t.Error("resource field must be absent when not configured")
	}
	if _, ok := m["description"]; ok {
		t.Error("description field must be absent when not configured")
	}
	if _, ok := m["mimeType"]; ok {
		t.Error("mimeType field must be absent when not configured")
	}
}

// ─── Check ────────────────────────────────────────────────────────────────────

func TestCheck_EmptySig(t *testing.T) {
	pw := makePaywall(t)
	result, err := pw.Check(context.Background(), "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsValid {
		t.Error("expected IsValid=false for empty sig")
	}
	if result.InvalidReason != "" {
		t.Errorf("expected no reason, got %q", result.InvalidReason)
	}
}

func TestCheck_InvalidBase64(t *testing.T) {
	pw := makePaywall(t)
	result, err := pw.Check(context.Background(), "!!!not-valid-base64!!!")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsValid {
		t.Error("expected IsValid=false for invalid base64")
	}
	if result.InvalidReason != "INVALID_PAYLOAD" {
		t.Errorf("expected INVALID_PAYLOAD, got %q", result.InvalidReason)
	}
}

func TestCheck_FacilitatorValid(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/x402/verify") {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"isValid":true}`))
	}))
	defer srv.Close()

	pw := makePaywall(t, func(o *remitmd.PaywallOptions) {
		o.FacilitatorURL = srv.URL
	})
	result, err := pw.Check(context.Background(), makeDummySig())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsValid {
		t.Error("expected IsValid=true")
	}
}

func TestCheck_FacilitatorInvalid(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"isValid":false,"invalidReason":"SIGNATURE_INVALID"}`))
	}))
	defer srv.Close()

	pw := makePaywall(t, func(o *remitmd.PaywallOptions) {
		o.FacilitatorURL = srv.URL
	})
	result, _ := pw.Check(context.Background(), makeDummySig())
	if result.IsValid {
		t.Error("expected IsValid=false")
	}
	if result.InvalidReason != "SIGNATURE_INVALID" {
		t.Errorf("expected SIGNATURE_INVALID, got %q", result.InvalidReason)
	}
}

func TestCheck_FacilitatorError(t *testing.T) {
	pw := makePaywall(t, func(o *remitmd.PaywallOptions) {
		o.FacilitatorURL = "http://127.0.0.1:0" // nothing listening
	})
	result, err := pw.Check(context.Background(), makeDummySig())
	if err != nil {
		t.Fatalf("Check must not return error on facilitator failure: %v", err)
	}
	if result.IsValid {
		t.Error("expected IsValid=false")
	}
	if result.InvalidReason != "FACILITATOR_ERROR" {
		t.Errorf("expected FACILITATOR_ERROR, got %q", result.InvalidReason)
	}
}

func TestCheck_AuthHeader(t *testing.T) {
	var capturedAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"isValid":true}`))
	}))
	defer srv.Close()

	pw := makePaywall(t, func(o *remitmd.PaywallOptions) {
		o.FacilitatorURL = srv.URL
		o.FacilitatorToken = "my-jwt"
	})
	_, _ = pw.Check(context.Background(), makeDummySig())

	if capturedAuth != "Bearer my-jwt" {
		t.Errorf("Authorization = %q, want %q", capturedAuth, "Bearer my-jwt")
	}
}

// ─── Middleware ───────────────────────────────────────────────────────────────

func TestMiddleware_Returns402WhenNoPay(t *testing.T) {
	pw := makePaywall(t)
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	handler := pw.Middleware()(next)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/data", nil))

	if rec.Code != http.StatusPaymentRequired {
		t.Errorf("status = %d, want 402", rec.Code)
	}
	if rec.Header().Get("PAYMENT-REQUIRED") == "" {
		t.Error("PAYMENT-REQUIRED header must be present")
	}
}

func TestMiddleware_ForwardsValidPayment(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"isValid":true}`))
	}))
	defer srv.Close()

	pw := makePaywall(t, func(o *remitmd.PaywallOptions) {
		o.FacilitatorURL = srv.URL
	})
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	handler := pw.Middleware()(next)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/data", nil)
	req.Header.Set("payment-signature", makeDummySig())
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rec.Code)
	}
}
