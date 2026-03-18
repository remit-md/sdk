# remitmd-go — Go SDK for remit.md

[![CI](https://github.com/remit-md/sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/remit-md/sdk/actions/workflows/ci.yml)

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

## Permits (Gasless USDC Approval)

```go
contracts, _ := wallet.GetContracts(ctx)

// Use permits with any payment method
tx, _ := wallet.Pay(ctx, "0xRecipient...", decimal.NewFromFloat(5.0),
    remitmd.WithPermit(permit))
```

Permit support is available on: `Pay`, `CreateEscrow`, `CreateTab`, `CreateStream`, `CreateBounty`, `PlaceDeposit`.

## All Methods

```go
// Contract discovery (cached per session)
wallet.GetContracts(ctx)                                    // *ContractAddresses

// Payments
wallet.Pay(ctx, to, amount, ...PayOption)                   // *Transaction (opts: WithMemo, WithPermit)
wallet.Balance(ctx)                                         // *Balance

// Escrow
wallet.CreateEscrow(ctx, payee, amount, ...EscrowOption)    // *Escrow (opts: WithMemo, WithPermit, WithMilestones)
wallet.ClaimStart(ctx, escrowID)                            // *Escrow
wallet.ReleaseEscrow(ctx, escrowID, milestoneIDs...)        // *Escrow
wallet.CancelEscrow(ctx, escrowID)                          // *Escrow
wallet.GetEscrow(ctx, escrowID)                             // *Escrow

// Tabs
wallet.CreateTab(ctx, provider, limit, perUnit, ...TabOption) // *Tab (opts: WithPermit, WithExpiresIn)
wallet.ChargeTab(ctx, tabID, amount, cumulative, callCount, providerSig) // *TabCharge
wallet.CloseTab(ctx, tabID, ...CloseTabOption)              // *Tab (opts: WithFinalAmount, WithProviderSig)
wallet.GetTab(ctx, tabID)                                   // *Tab

// Streams
wallet.CreateStream(ctx, payee, rate, maxTotal, ...StreamOption) // *Stream (opts: WithPermit)
wallet.CloseStream(ctx, streamID)                           // *Stream
wallet.WithdrawStream(ctx, streamID)                        // *Transaction

// Bounties
wallet.CreateBounty(ctx, amount, task, deadline, ...BountyOption) // *Bounty (opts: WithPermit, WithMaxAttempts)
wallet.SubmitBounty(ctx, bountyID, evidenceHash)            // *BountySubmission
wallet.AwardBounty(ctx, bountyID, submissionID)             // *Bounty
wallet.ListBounties(ctx, opts)                              // []Bounty

// Deposits
wallet.PlaceDeposit(ctx, provider, amount, expires, ...DepositOption) // *Deposit (opts: WithPermit)
wallet.ReturnDeposit(ctx, depositID)                        // *Transaction

// Status & analytics
wallet.SpendingSummary(ctx, period)                         // *SpendingSummary
wallet.RemainingBudget(ctx)                                 // *Budget
wallet.History(ctx, opts)                                   // *TransactionList
wallet.Reputation(ctx, address)                             // *Reputation

// Webhooks
wallet.RegisterWebhook(ctx, url, events, chains...)         // *Webhook

// Operator links
wallet.CreateFundLink(ctx)                                  // *LinkResponse
wallet.CreateWithdrawLink(ctx)                              // *LinkResponse

// Testnet
wallet.Mint(ctx, amount)                                    // *MintResponse
```

## Error Handling

All errors are `*RemitError` with machine-readable codes and actionable details:

```go
tx, err := wallet.Pay(ctx, recipient, amount)
var remitErr *remitmd.RemitError
if errors.As(err, &remitErr) {
    fmt.Println(remitErr.Code)    // "INSUFFICIENT_BALANCE"
    fmt.Println(remitErr.Message) // "Insufficient USDC balance: have $5.00, need $100.00"
    // Enriched errors include details with actual numbers
}
```

## Chains

| Chain | Identifier | Status |
|-------|-----------|--------|
| Base | `"base"` | Mainnet |
| Base Sepolia | `"base"` + `WithTestnet()` | Testnet |
