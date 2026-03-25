package remitmd_test

import (
	"context"
	"testing"

	"github.com/remit-md/sdk/go"
	"github.com/shopspring/decimal"
)

func TestMockBalance(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	bal, err := wallet.Balance(ctx)
	if err != nil {
		t.Fatalf("Balance failed: %v", err)
	}
	if !bal.USDC.Equal(decimal.NewFromInt(10_000)) {
		t.Errorf("expected 10000 USDC, got %s", bal.USDC.String())
	}
}

func TestMockCustomBalance(t *testing.T) {
	custom := decimal.NewFromFloat(42.50)
	mock := remitmd.NewMockRemit(custom)
	wallet := mock.Wallet()
	ctx := context.Background()

	bal, err := wallet.Balance(ctx)
	if err != nil {
		t.Fatalf("Balance failed: %v", err)
	}
	if !bal.USDC.Equal(custom) {
		t.Errorf("expected %s USDC, got %s", custom.String(), bal.USDC.String())
	}
}

func TestMockSetBalance(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	newBal := decimal.NewFromFloat(999.99)
	mock.SetBalance(newBal)

	bal, err := wallet.Balance(ctx)
	if err != nil {
		t.Fatalf("Balance failed: %v", err)
	}
	if !bal.USDC.Equal(newBal) {
		t.Errorf("expected %s, got %s", newBal.String(), bal.USDC.String())
	}
}

func TestMockTotalPaidTo(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	recipient := "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
	wallet.Pay(ctx, recipient, decimal.NewFromFloat(1.00)) //nolint:errcheck
	wallet.Pay(ctx, recipient, decimal.NewFromFloat(2.50)) //nolint:errcheck

	total := mock.TotalPaidTo(recipient)
	expected := decimal.NewFromFloat(3.50)
	if !total.Equal(expected) {
		t.Errorf("TotalPaidTo: got %s, want %s", total.String(), expected.String())
	}
}

func TestMockWasPaid_NotPaid(t *testing.T) {
	mock := remitmd.NewMockRemit()
	if mock.WasPaid("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", decimal.NewFromFloat(1.00)) {
		t.Error("WasPaid should be false before any payment")
	}
}

func TestMockTransactions(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	if len(mock.Transactions()) != 0 {
		t.Error("expected 0 transactions initially")
	}

	wallet.Pay(ctx, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", decimal.NewFromFloat(5.00)) //nolint:errcheck

	if len(mock.Transactions()) != 1 {
		t.Errorf("expected 1 transaction, got %d", len(mock.Transactions()))
	}
}

func TestMockHistory(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	wallet.Pay(ctx, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", decimal.NewFromFloat(1.00)) //nolint:errcheck

	list, err := wallet.History(ctx, nil)
	if err != nil {
		t.Fatalf("History failed: %v", err)
	}
	if list.Total != 1 {
		t.Errorf("expected 1 item in history, got %d", list.Total)
	}
}

func TestMockReputation(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	addr := "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
	rep, err := wallet.Reputation(ctx, addr)
	if err != nil {
		t.Fatalf("Reputation failed: %v", err)
	}
	if rep.Score != 750 {
		t.Errorf("expected score 750, got %d", rep.Score)
	}
}

func TestMockEscrowClaimStart(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	payee := "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
	escrow, err := wallet.CreateEscrow(ctx, payee, decimal.NewFromFloat(10.00))
	if err != nil {
		t.Fatalf("CreateEscrow failed: %v", err)
	}

	tx, err := wallet.ClaimStart(ctx, escrow.InvoiceID)
	if err != nil {
		t.Fatalf("ClaimStartEscrow failed: %v", err)
	}
	if tx.TxHash == "" {
		t.Error("expected non-empty TxHash after ClaimStart")
	}
}

func TestMockEscrowNotFound(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	_, err := wallet.ReleaseEscrow(ctx, "nonexistent")
	if err == nil {
		t.Fatal("expected error for nonexistent escrow")
	}
}

func TestMockAddress(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	addr := wallet.Address()
	if addr == "" {
		t.Error("Address() returned empty")
	}
}

func TestMockChainID(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	if wallet.ChainID() != remitmd.ChainBaseSep {
		t.Errorf("expected ChainBaseSep, got %d", wallet.ChainID())
	}
}

func TestValidateAmount_Zero(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	_, err := wallet.Pay(ctx, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", decimal.Zero)
	if err == nil {
		t.Fatal("expected error for zero amount")
	}
}

func TestValidateAmount_Negative(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	_, err := wallet.Pay(ctx, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", decimal.NewFromFloat(-1.00))
	if err == nil {
		t.Fatal("expected error for negative amount")
	}
}
