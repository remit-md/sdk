package remitmd_test

import (
	"context"
	"testing"

	"github.com/remit-md/sdk/go"
	"github.com/shopspring/decimal"
)

// TestMockPay verifies the basic payment flow using MockRemit.
func TestMockPay(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	recipient := "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
	amount := decimal.NewFromFloat(1.50)

	tx, err := wallet.Pay(ctx, recipient, amount, remitmd.WithMemo("test payment"))
	if err != nil {
		t.Fatalf("Pay failed: %v", err)
	}
	if tx.ID == "" {
		t.Error("expected non-empty transaction ID")
	}
	if tx.Amount == nil || !tx.Amount.Equal(amount) {
		t.Errorf("amount mismatch: got %v, want %s", tx.Amount, amount.String())
	}
	if !mock.WasPaid(recipient, amount) {
		t.Error("WasPaid returned false after payment")
	}
}

// TestMockPayInsufficientFunds verifies the insufficient-funds error path.
func TestMockPayInsufficientFunds(t *testing.T) {
	mock := remitmd.NewMockRemit(decimal.NewFromFloat(0.50))
	wallet := mock.Wallet()
	ctx := context.Background()

	_, err := wallet.Pay(ctx, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", decimal.NewFromFloat(1.00))
	if err == nil {
		t.Fatal("expected error for insufficient funds, got nil")
	}
	var remitErr *remitmd.RemitError
	if !errorAs(err, &remitErr) {
		t.Fatalf("expected *RemitError, got %T", err)
	}
	if remitErr.Code != remitmd.ErrCodeInsufficientFunds {
		t.Errorf("expected code %s, got %s", remitmd.ErrCodeInsufficientFunds, remitErr.Code)
	}
}

// TestMockEscrowLifecycle verifies create → release escrow flow.
func TestMockEscrowLifecycle(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	payee := "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
	amount := decimal.NewFromFloat(10.00)

	escrow, err := wallet.CreateEscrow(ctx, payee, amount, remitmd.WithEscrowMemo("audit work"))
	if err != nil {
		t.Fatalf("CreateEscrow failed: %v", err)
	}
	if escrow.Status != remitmd.EscrowStatusFunded {
		t.Errorf("expected status %s, got %s", remitmd.EscrowStatusFunded, escrow.Status)
	}

	released, err := wallet.ReleaseEscrow(ctx, escrow.InvoiceID)
	if err != nil {
		t.Fatalf("ReleaseEscrow failed: %v", err)
	}
	if released.TxHash == "" {
		t.Error("expected non-empty tx_hash after release")
	}
}

// TestMockEscrowCancel verifies escrow cancellation returns funds.
func TestMockEscrowCancel(t *testing.T) {
	startBalance := decimal.NewFromInt(100)
	mock := remitmd.NewMockRemit(startBalance)
	wallet := mock.Wallet()
	ctx := context.Background()

	amount := decimal.NewFromFloat(50.00)
	escrow, _ := wallet.CreateEscrow(ctx, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", amount)
	_, err := wallet.CancelEscrow(ctx, escrow.InvoiceID)
	if err != nil {
		t.Fatalf("CancelEscrow failed: %v", err)
	}

	bal, _ := wallet.Balance(ctx)
	if !bal.USDC.Equal(startBalance) {
		t.Errorf("balance after cancel: got %s, want %s", bal.USDC.String(), startBalance.String())
	}
}

// TestValidateAddress verifies address validation rejects bad inputs.
func TestValidateAddress(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	cases := []string{
		"",
		"not-an-address",
		"0x123",                         // too short
		"d8dA6BF26964aF9D7eEd9e03E53415D37aA96045", // missing 0x
	}
	for _, addr := range cases {
		_, err := wallet.Pay(ctx, addr, decimal.NewFromFloat(1.00))
		if err == nil {
			t.Errorf("expected error for invalid address %q, got nil", addr)
		}
		var remitErr *remitmd.RemitError
		if !errorAs(err, &remitErr) {
			t.Errorf("expected *RemitError for %q, got %T", addr, err)
			continue
		}
		if remitErr.Code != remitmd.ErrCodeInvalidAddress {
			t.Errorf("expected %s for %q, got %s", remitmd.ErrCodeInvalidAddress, addr, remitErr.Code)
		}
	}
}

// TestMockReset verifies Reset() clears recorded state.
func TestMockReset(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	wallet.Pay(ctx, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", decimal.NewFromFloat(1.00)) //nolint:errcheck
	mock.Reset()

	if len(mock.Transactions()) != 0 {
		t.Error("Reset() did not clear transactions")
	}
}

// errorAs is a simple errors.As replacement to avoid adding the errors import.
func errorAs(err error, target **remitmd.RemitError) bool {
	if e, ok := err.(*remitmd.RemitError); ok {
		*target = e
		return true
	}
	return false
}
