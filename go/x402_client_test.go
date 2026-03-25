package remitmd_test

import (
	"errors"
	"testing"

	remitmd "github.com/remit-md/sdk/go"
)

func TestNewX402Client_DefaultLimit(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()

	client := remitmd.NewX402Client(wallet)
	if client.MaxAutoPayUsdc != 0.10 {
		t.Errorf("expected default limit 0.10, got %f", client.MaxAutoPayUsdc)
	}
}

func TestNewX402Client_CustomLimit(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()

	client := remitmd.NewX402Client(wallet, 5.0)
	if client.MaxAutoPayUsdc != 5.0 {
		t.Errorf("expected limit 5.0, got %f", client.MaxAutoPayUsdc)
	}
}

func TestNewX402Client_ZeroLimitUsesDefault(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()

	client := remitmd.NewX402Client(wallet, 0)
	if client.MaxAutoPayUsdc != 0.10 {
		t.Errorf("expected default limit 0.10 for zero input, got %f", client.MaxAutoPayUsdc)
	}
}

func TestAllowanceExceededError_Message(t *testing.T) {
	err := &remitmd.AllowanceExceededError{AmountUsdc: 1.5, LimitUsdc: 0.10}
	msg := err.Error()
	if msg == "" {
		t.Fatal("expected non-empty error message")
	}
}

func TestAllowanceExceededError_ErrorsAs(t *testing.T) {
	err := &remitmd.AllowanceExceededError{AmountUsdc: 2.0, LimitUsdc: 0.10}
	var target *remitmd.AllowanceExceededError
	if !errors.As(err, &target) {
		t.Fatal("errors.As should match AllowanceExceededError")
	}
	if target.AmountUsdc != 2.0 {
		t.Errorf("expected amount 2.0, got %f", target.AmountUsdc)
	}
	if target.LimitUsdc != 0.10 {
		t.Errorf("expected limit 0.10, got %f", target.LimitUsdc)
	}
}

func TestPaymentRequired_Fields(t *testing.T) {
	pr := remitmd.PaymentRequired{
		Scheme:            "exact",
		Network:           "eip155:84532",
		Amount:            "1000",
		Asset:             "0x2d846325766921935f37d5b4478196d3ef93707c",
		PayTo:             "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
		MaxTimeoutSeconds: 60,
		Resource:          "/v1/data",
		Description:       "test data",
		MimeType:          "application/json",
	}
	if pr.Scheme != "exact" {
		t.Errorf("expected scheme exact, got %s", pr.Scheme)
	}
	if pr.Resource != "/v1/data" {
		t.Errorf("expected resource /v1/data, got %s", pr.Resource)
	}
}

func TestX402Response_NilPayment(t *testing.T) {
	resp := remitmd.X402Response{
		Response:    nil,
		LastPayment: nil,
	}
	if resp.LastPayment != nil {
		t.Error("expected nil last payment")
	}
}
