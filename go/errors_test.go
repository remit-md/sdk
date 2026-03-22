package remitmd_test

import (
	"testing"

	"github.com/remit-md/sdk/go"
)

func TestRemitError_Error(t *testing.T) {
	err := &remitmd.RemitError{
		Code:    "TEST_ERROR",
		Message: "something went wrong",
		DocURL:  "https://remit.md/docs/errors#TEST_ERROR",
	}
	got := err.Error()
	if got == "" {
		t.Fatal("Error() returned empty string")
	}
	// Should contain the code
	if !containsStr(got, "TEST_ERROR") {
		t.Errorf("Error() should contain code, got: %s", got)
	}
	if !containsStr(got, "something went wrong") {
		t.Errorf("Error() should contain message, got: %s", got)
	}
}

func TestRemitError_WithContext(t *testing.T) {
	err := &remitmd.RemitError{
		Code:    "INVALID_ADDRESS",
		Message: "bad address",
		DocURL:  "https://remit.md/docs/errors#INVALID_ADDRESS",
		Context: map[string]any{"address": "0xbad"},
	}
	if err.Context["address"] != "0xbad" {
		t.Error("Context not preserved")
	}
}

func containsStr(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(s) > 0 && stringContains(s, sub))
}

func stringContains(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
