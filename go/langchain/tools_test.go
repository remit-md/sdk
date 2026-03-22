package langchain_test

import (
	"context"
	"testing"

	remitmd "github.com/remit-md/sdk/go"
	"github.com/remit-md/sdk/go/langchain"
	"github.com/shopspring/decimal"
)

func TestNewTools(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()

	tools := langchain.NewTools(wallet)
	if len(tools) != 4 {
		t.Fatalf("expected 4 tools, got %d", len(tools))
	}

	expectedNames := []string{"remitmd_pay", "remitmd_balance", "remitmd_create_escrow", "remitmd_check_escrow"}
	for i, tool := range tools {
		if tool.Name() != expectedNames[i] {
			t.Errorf("tool[%d]: expected name %q, got %q", i, expectedNames[i], tool.Name())
		}
		if tool.Description() == "" {
			t.Errorf("tool %q has empty description", tool.Name())
		}
		if tool.Schema() == nil {
			t.Errorf("tool %q has nil schema", tool.Name())
		}
	}
}

func TestPayTool_Call(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	tools := langchain.NewTools(wallet)
	payTool := tools[0]
	ctx := context.Background()

	result, err := payTool.Call(ctx, `{"recipient":"0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045","amount_usdc":1.5,"memo":"test"}`)
	if err != nil {
		t.Fatalf("PayTool.Call failed: %v", err)
	}
	if result == "" {
		t.Error("expected non-empty result")
	}
	if !mock.WasPaid("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", decimal.NewFromFloat(1.5)) {
		t.Error("payment not recorded")
	}
}

func TestPayTool_InvalidInput(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	tools := langchain.NewTools(wallet)
	payTool := tools[0]
	ctx := context.Background()

	_, err := payTool.Call(ctx, `not json`)
	if err == nil {
		t.Error("expected error for invalid JSON input")
	}
}

func TestBalanceTool_Call(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	tools := langchain.NewTools(wallet)
	balanceTool := tools[1]
	ctx := context.Background()

	result, err := balanceTool.Call(ctx, `{}`)
	if err != nil {
		t.Fatalf("BalanceTool.Call failed: %v", err)
	}
	if result == "" {
		t.Error("expected non-empty result")
	}
}

func TestCreateEscrowTool_Call(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	tools := langchain.NewTools(wallet)
	escrowTool := tools[2]
	ctx := context.Background()

	result, err := escrowTool.Call(ctx, `{"payee":"0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045","amount_usdc":10.0,"description":"test work"}`)
	if err != nil {
		t.Fatalf("CreateEscrowTool.Call failed: %v", err)
	}
	if result == "" {
		t.Error("expected non-empty result")
	}
}

func TestCheckEscrowTool_Call(t *testing.T) {
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	// Create escrow first
	payee := "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
	escrow, err := wallet.CreateEscrow(ctx, payee, decimal.NewFromFloat(5.00))
	if err != nil {
		t.Fatalf("CreateEscrow failed: %v", err)
	}

	tools := langchain.NewTools(wallet)
	checkTool := tools[3]

	result, err := checkTool.Call(ctx, `{"escrow_id":"`+escrow.InvoiceID+`"}`)
	if err != nil {
		t.Fatalf("CheckEscrowTool.Call failed: %v", err)
	}
	if result == "" {
		t.Error("expected non-empty result")
	}
}
