// Example: Send a direct USDC payment using remit.md
//
// Usage:
//
//	export REMITMD_KEY=0x...  (your private key)
//	go run ./examples/pay
package main

import (
	"context"
	"fmt"
	"log"
	"os"

	"github.com/remit-md/sdk/go"
	"github.com/shopspring/decimal"
)

func main() {
	wallet, err := remitmd.FromEnv(remitmd.WithTestnet())
	if err != nil {
		log.Fatalf("failed to create wallet: %v", err)
	}

	fmt.Printf("Wallet address: %s\n", wallet.Address())

	bal, err := wallet.Balance(context.Background())
	if err != nil {
		log.Fatalf("failed to get balance: %v", err)
	}
	fmt.Printf("Balance: %s USDC\n", bal.USDC.String())

	recipient := os.Getenv("RECIPIENT_ADDRESS")
	if recipient == "" {
		recipient = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
	}

	tx, err := wallet.Pay(
		context.Background(),
		recipient,
		decimal.NewFromFloat(1.00),
		remitmd.WithMemo("example payment"),
	)
	if err != nil {
		log.Fatalf("payment failed: %v", err)
	}

	fmt.Printf("Payment sent!\n")
	fmt.Printf("  Transaction ID: %s\n", tx.ID)
	fmt.Printf("  Amount: %s USDC\n", tx.Amount.String())
	fmt.Printf("  To: %s\n", tx.To)
}
