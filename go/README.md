# remitmd-go — Go SDK for remit.md

Universal AI payment protocol for agents on EVM L2 chains.

## Install

```bash
go get github.com/remit-md/sdk-go
```

## Quick Start

```go
import (
    "context"
    "github.com/remit-md/sdk-go"
    "github.com/shopspring/decimal"
)

// From environment variable REMITMD_KEY
wallet, err := remitmd.FromEnv()

// Or with explicit key
wallet, err := remitmd.NewWallet(os.Getenv("REMITMD_KEY"), remitmd.WithChain("base"))

// Send 1.50 USDC
tx, err := wallet.Pay(ctx, "0xRecipient...", decimal.NewFromFloat(1.50))
```

## Testing (Zero Network)

```go
mock := remitmd.NewMockRemit()
wallet := mock.Wallet()

tx, err := wallet.Pay(ctx, "0xRecipient", decimal.NewFromFloat(1.50))
assert.True(t, mock.WasPaid("0xRecipient", decimal.NewFromFloat(1.50)))
```

## LangChain/LangGraph Integration

```go
import "github.com/remit-md/sdk-go/langchain"

tools := langchain.NewTools(wallet)
// Register with your agent framework
for _, tool := range tools {
    agent.RegisterTool(tool)
}
```

## Features

- Direct payments (`wallet.Pay`)
- Escrow (`wallet.CreateEscrow`, `wallet.ReleaseEscrow`, `wallet.CancelEscrow`)
- Tabs / payment channels (`wallet.CreateTab`, `wallet.DebitTab`, `wallet.SettleTab`)
- Streaming payments (`wallet.CreateStream`, `wallet.WithdrawStream`)
- Bounties (`wallet.CreateBounty`, `wallet.AwardBounty`)
- Security deposits (`wallet.LockDeposit`)
- Spending analytics (`wallet.SpendingSummary`, `wallet.RemainingBudget`)
- Reputation queries (`wallet.Reputation`)

## Error Handling

All errors are `*RemitError` with machine-readable codes:

```go
tx, err := wallet.Pay(ctx, badAddr, amount)
var remitErr *remitmd.RemitError
if errors.As(err, &remitErr) {
    fmt.Println(remitErr.Code)    // "INVALID_ADDRESS"
    fmt.Println(remitErr.DocURL)  // "https://remit.md/docs/errors#INVALID_ADDRESS"
}
```

## Chains

| Chain | Identifier | Status |
|-------|-----------|--------|
| Base | `"base"` | Mainnet |
| Base Sepolia | `"base"` + `WithTestnet()` | Testnet |
| Arbitrum | `"arbitrum"` | Coming soon |
| Optimism | `"optimism"` | Coming soon |
