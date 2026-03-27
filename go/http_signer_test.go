package remitmd_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	remitmd "github.com/remit-md/sdk/go"
)

const (
	mockAddress   = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
	mockSignature = "0x" + "ab" + "ab" + "ab" + "ab" + "ab" + "ab" + "ab" + "ab" +
		"ab" + "ab" + "ab" + "ab" + "ab" + "ab" + "ab" + "ab" +
		"ab" + "ab" + "ab" + "ab" + "ab" + "ab" + "ab" + "ab" +
		"ab" + "ab" + "ab" + "ab" + "ab" + "ab" + "ab" + "ab" +
		"cd" + "cd" + "cd" + "cd" + "cd" + "cd" + "cd" + "cd" +
		"cd" + "cd" + "cd" + "cd" + "cd" + "cd" + "cd" + "cd" +
		"cd" + "cd" + "cd" + "cd" + "cd" + "cd" + "cd" + "cd" +
		"cd" + "cd" + "cd" + "cd" + "cd" + "cd" + "cd" + "cd" +
		"1b"
	validToken = "rmit_sk_test_token_abc123"
)

// newMockSignerServer creates a test HTTP server that mimics the signer server.
func newMockSignerServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Check auth on all routes
		auth := r.Header.Get("Authorization")
		if auth != "Bearer "+validToken {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(401)
			json.NewEncoder(w).Encode(map[string]string{"error": "unauthorized"}) //nolint:errcheck
			return
		}

		switch {
		case r.Method == "GET" && r.URL.Path == "/address":
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]string{"address": mockAddress}) //nolint:errcheck

		case r.Method == "POST" && r.URL.Path == "/sign/digest":
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]string{"signature": mockSignature}) //nolint:errcheck

		default:
			w.WriteHeader(404)
			json.NewEncoder(w).Encode(map[string]string{"error": "not_found"}) //nolint:errcheck
		}
	}))
}

// TestHttpSigner_HappyPath verifies address caching and signing.
func TestHttpSigner_HappyPath(t *testing.T) {
	srv := newMockSignerServer(t)
	defer srv.Close()

	signer, err := remitmd.NewHttpSigner(srv.URL, validToken)
	if err != nil {
		t.Fatalf("NewHttpSigner failed: %v", err)
	}

	// Address should be cached from construction
	addr := signer.Address()
	if !strings.EqualFold(addr.Hex(), mockAddress) {
		t.Errorf("Address mismatch: got %s, want %s", addr.Hex(), mockAddress)
	}

	// Sign a digest
	digest := [32]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
		17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32}

	sig, err := signer.Sign(digest)
	if err != nil {
		t.Fatalf("Sign failed: %v", err)
	}
	if len(sig) != 65 {
		t.Errorf("expected 65-byte signature, got %d bytes", len(sig))
	}
}

// TestHttpSigner_Unreachable verifies error when server is down.
func TestHttpSigner_Unreachable(t *testing.T) {
	_, err := remitmd.NewHttpSigner("http://127.0.0.1:1", validToken)
	if err == nil {
		t.Fatal("expected error for unreachable server, got nil")
	}
	var remitErr *remitmd.RemitError
	if !httpSignerErrorAs(err, &remitErr) {
		t.Fatalf("expected *RemitError, got %T: %v", err, err)
	}
	if remitErr.Code != remitmd.ErrCodeNetworkError {
		t.Errorf("expected code %s, got %s", remitmd.ErrCodeNetworkError, remitErr.Code)
	}
}

// TestHttpSigner_Unauthorized verifies 401 handling.
func TestHttpSigner_Unauthorized(t *testing.T) {
	srv := newMockSignerServer(t)
	defer srv.Close()

	_, err := remitmd.NewHttpSigner(srv.URL, "wrong_token")
	if err == nil {
		t.Fatal("expected error for bad token, got nil")
	}
	var remitErr *remitmd.RemitError
	if !httpSignerErrorAs(err, &remitErr) {
		t.Fatalf("expected *RemitError, got %T: %v", err, err)
	}
	if remitErr.Code != remitmd.ErrCodeUnauthorized {
		t.Errorf("expected code %s, got %s", remitmd.ErrCodeUnauthorized, remitErr.Code)
	}
	// Token must not appear in error message
	if strings.Contains(remitErr.Message, "wrong_token") {
		t.Error("error message must not contain the bearer token")
	}
}

// TestHttpSigner_PolicyDenied verifies 403 handling with reason.
func TestHttpSigner_PolicyDenied(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == "GET" && r.URL.Path == "/address":
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]string{"address": mockAddress}) //nolint:errcheck
		case r.Method == "POST" && r.URL.Path == "/sign/digest":
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(403)
			json.NewEncoder(w).Encode(map[string]interface{}{
				"error":  "policy_denied",
				"reason": "chain not allowed",
			}) //nolint:errcheck
		}
	}))
	defer srv.Close()

	signer, err := remitmd.NewHttpSigner(srv.URL, validToken)
	if err != nil {
		t.Fatalf("NewHttpSigner failed: %v", err)
	}

	digest := [32]byte{}
	_, err = signer.Sign(digest)
	if err == nil {
		t.Fatal("expected error for 403, got nil")
	}
	var remitErr *remitmd.RemitError
	if !httpSignerErrorAs(err, &remitErr) {
		t.Fatalf("expected *RemitError, got %T: %v", err, err)
	}
	if remitErr.Code != "POLICY_DENIED" {
		t.Errorf("expected code POLICY_DENIED, got %s", remitErr.Code)
	}
	if !strings.Contains(remitErr.Message, "chain not allowed") {
		t.Errorf("expected reason in message, got: %s", remitErr.Message)
	}
}

// TestHttpSigner_ServerError verifies 500 handling.
func TestHttpSigner_ServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == "GET" && r.URL.Path == "/address":
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]string{"address": mockAddress}) //nolint:errcheck
		case r.Method == "POST" && r.URL.Path == "/sign/digest":
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(500)
			json.NewEncoder(w).Encode(map[string]string{"error": "internal_error"}) //nolint:errcheck
		}
	}))
	defer srv.Close()

	signer, err := remitmd.NewHttpSigner(srv.URL, validToken)
	if err != nil {
		t.Fatalf("NewHttpSigner failed: %v", err)
	}

	digest := [32]byte{}
	_, err = signer.Sign(digest)
	if err == nil {
		t.Fatal("expected error for 500, got nil")
	}
	var remitErr *remitmd.RemitError
	if !httpSignerErrorAs(err, &remitErr) {
		t.Fatalf("expected *RemitError, got %T: %v", err, err)
	}
	if remitErr.Code != remitmd.ErrCodeServerError {
		t.Errorf("expected code %s, got %s", remitmd.ErrCodeServerError, remitErr.Code)
	}
}

// TestHttpSigner_MalformedResponse verifies handling of non-JSON response.
func TestHttpSigner_MalformedResponse(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == "GET" && r.URL.Path == "/address":
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]string{"address": mockAddress}) //nolint:errcheck
		case r.Method == "POST" && r.URL.Path == "/sign/digest":
			w.Header().Set("Content-Type", "text/plain")
			w.Write([]byte("this is not json")) //nolint:errcheck
		}
	}))
	defer srv.Close()

	signer, err := remitmd.NewHttpSigner(srv.URL, validToken)
	if err != nil {
		t.Fatalf("NewHttpSigner failed: %v", err)
	}

	digest := [32]byte{}
	_, err = signer.Sign(digest)
	if err == nil {
		t.Fatal("expected error for malformed response, got nil")
	}
	var remitErr *remitmd.RemitError
	if !httpSignerErrorAs(err, &remitErr) {
		t.Fatalf("expected *RemitError, got %T: %v", err, err)
	}
	if remitErr.Code != remitmd.ErrCodeServerError {
		t.Errorf("expected code %s, got %s", remitmd.ErrCodeServerError, remitErr.Code)
	}
}

// TestHttpSigner_BadSignatureHex verifies handling of invalid hex in signature.
func TestHttpSigner_BadSignatureHex(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == "GET" && r.URL.Path == "/address":
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]string{"address": mockAddress}) //nolint:errcheck
		case r.Method == "POST" && r.URL.Path == "/sign/digest":
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]string{"signature": "0xNOTHEX"}) //nolint:errcheck
		}
	}))
	defer srv.Close()

	signer, err := remitmd.NewHttpSigner(srv.URL, validToken)
	if err != nil {
		t.Fatalf("NewHttpSigner failed: %v", err)
	}

	digest := [32]byte{}
	_, err = signer.Sign(digest)
	if err == nil {
		t.Fatal("expected error for bad hex signature, got nil")
	}
	var remitErr *remitmd.RemitError
	if !httpSignerErrorAs(err, &remitErr) {
		t.Fatalf("expected *RemitError, got %T: %v", err, err)
	}
	if remitErr.Code != remitmd.ErrCodeServerError {
		t.Errorf("expected code %s, got %s", remitmd.ErrCodeServerError, remitErr.Code)
	}
}

// TestHttpSigner_StringNoToken verifies token does not leak in String().
func TestHttpSigner_StringNoToken(t *testing.T) {
	srv := newMockSignerServer(t)
	defer srv.Close()

	signer, err := remitmd.NewHttpSigner(srv.URL, validToken)
	if err != nil {
		t.Fatalf("NewHttpSigner failed: %v", err)
	}

	s := signer.String()
	if strings.Contains(s, validToken) {
		t.Error("String() must not contain the bearer token")
	}
	if !strings.Contains(s, "HttpSigner") {
		t.Error("String() should identify as HttpSigner")
	}
}

// TestHttpSigner_SignUnauthorized verifies 401 on Sign (not just constructor).
func TestHttpSigner_SignUnauthorized(t *testing.T) {
	// Server that accepts address but rejects sign
	callCount := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == "GET" && r.URL.Path == "/address":
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]string{"address": mockAddress}) //nolint:errcheck
		case r.Method == "POST" && r.URL.Path == "/sign/digest":
			callCount++
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(401)
			json.NewEncoder(w).Encode(map[string]string{"error": "unauthorized"}) //nolint:errcheck
		}
	}))
	defer srv.Close()

	signer, err := remitmd.NewHttpSigner(srv.URL, validToken)
	if err != nil {
		t.Fatalf("NewHttpSigner failed: %v", err)
	}

	digest := [32]byte{}
	_, err = signer.Sign(digest)
	if err == nil {
		t.Fatal("expected error for 401 on sign, got nil")
	}
	var remitErr *remitmd.RemitError
	if !httpSignerErrorAs(err, &remitErr) {
		t.Fatalf("expected *RemitError, got %T: %v", err, err)
	}
	if remitErr.Code != remitmd.ErrCodeUnauthorized {
		t.Errorf("expected code %s, got %s", remitmd.ErrCodeUnauthorized, remitErr.Code)
	}
}

// httpSignerErrorAs is a local errors.As replacement (matches wallet_test.go pattern).
func httpSignerErrorAs(err error, target **remitmd.RemitError) bool {
	if e, ok := err.(*remitmd.RemitError); ok {
		*target = e
		return true
	}
	return false
}
