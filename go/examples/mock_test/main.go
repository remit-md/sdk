// Example: Test agent payment logic using MockRemit (no network required)
//
// Run with:
//
//	go run ./examples/mock_test
package main

import (
	"context"
	"fmt"
	"log"

	"github.com/remit-md/sdk-go"
	"github.com/shopspring/decimal"
)

func main() {
	// Set up mock — no network, no private key required
	mock := remitmd.NewMockRemit()
	wallet := mock.Wallet()
	ctx := context.Background()

	fmt.Println("=== remit.md MockRemit Example ===")

	// Check initial balance
	bal, err := wallet.Balance(ctx)
	if err != nil {
		log.Fatalf("Balance failed: %v", err)
	}
	fmt.Printf("Starting balance: %s USDC\n", bal.USDC.String())

	// Send a payment
	recipient := "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
	amount := decimal.NewFromFloat(5.00)
	tx, err := wallet.Pay(ctx, recipient, amount, remitmd.WithMemo("service fee"))
	if err != nil {
		log.Fatalf("Pay failed: %v", err)
	}
	fmt.Printf("Paid %s USDC → %s (tx: %s)\n", amount, recipient, tx.ID)

	// Verify payment was recorded
	fmt.Printf("WasPaid: %v\n", mock.WasPaid(recipient, amount))
	fmt.Printf("Total paid to recipient: %s USDC\n", mock.TotalPaidTo(recipient))

	// Create and release an escrow
	escrow, err := wallet.CreateEscrow(ctx, recipient, decimal.NewFromFloat(10.00),
		remitmd.WithEscrowMemo("data analysis task"),
	)
	if err != nil {
		log.Fatalf("CreateEscrow failed: %v", err)
	}
	fmt.Printf("Escrow created: %s (status: %s, amount: %s USDC)\n",
		escrow.InvoiceID, escrow.Status, escrow.Amount)

	// Release escrow after work is done
	relTx, err := wallet.ReleaseEscrow(ctx, escrow.InvoiceID)
	if err != nil {
		log.Fatalf("ReleaseEscrow failed: %v", err)
	}
	fmt.Printf("Escrow released: %s USDC to %s\n", relTx.Amount, relTx.Payee)

	// Final balance
	bal, _ = wallet.Balance(ctx)
	fmt.Printf("Final balance: %s USDC\n", bal.USDC.String())

	// Transaction history
	history, _ := wallet.History(ctx, nil)
	fmt.Printf("Total transactions recorded: %d\n", len(history.Items))
}
