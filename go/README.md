# remitmd-go — Go SDK for remit.md

> [Skill MD](https://remit.md) · [Docs](https://remit.md/docs) · [Agent Spec](https://remit.md/agent.md)

[![CI](https://github.com/remit-md/sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/remit-md/sdk/actions/workflows/ci.yml)

Universal AI payment protocol for agents on EVM L2 chains.

## Install

```bash
go get github.com/remit-md/sdk/go
```

## Quick Start

```go
import (
    "context"
    "github.com/remit-md/sdk/go"
    "github.com/shopspring/decimal"
)

// From environment variable REMITMD_KEY
wallet, err := remitmd.FromEnv()

// Or with explicit key
wallet, err := remitmd.NewWallet(os.Getenv("REMITMD_KEY"), remitmd.WithChain("base"))

// Send 1.50 USDC — permit is signed automatically
tx, err := wallet.Pay(ctx, "0xRecipient...", decimal.NewFromFloat(1.50))

// Create an escrow — one call, no permit boilerplate
escrow, err := wallet.CreateEscrow(ctx, "0xPayee...", decimal.NewFromFloat(10.0),
    remitmd.WithEscrowMemo("design work"))
```

All payment methods (`Pay`, `CreateEscrow`, `CreateTab`, `CreateStream`, `CreateBounty`, `PlaceDeposit`) auto-sign an EIP-2612 permit when none is provided. No manual approval step needed.

## Testing (Zero Network)

```go
mock := remitmd.NewMockRemit()
wallet := mock.Wallet()

tx, err := wallet.Pay(ctx, "0xRecipient", decimal.NewFromFloat(1.50))
assert.True(t, mock.WasPaid("0xRecipient", decimal.NewFromFloat(1.50)))
```

## LangChain/LangGraph Integration

```go
import "github.com/remit-md/sdk/go/langchain"

tools := langchain.NewTools(wallet)
// Register with your agent framework
for _, tool := range tools {
    agent.RegisterTool(tool)
}
```

## All Methods

```go
// Contract discovery (cached per session)
wallet.GetContracts(ctx)                                    // *ContractAddresses

// Permits (auto-signed when omitted — see Advanced section)
wallet.SignPermit(ctx, spender, amount, deadline...)        // *PermitSignature

// Payments (auto-permit built in)
wallet.Pay(ctx, to, amount, ...PayOption)                   // *Transaction (opts: WithMemo, WithPayPermit)
wallet.Balance(ctx)                                         // *Balance

// Escrow (auto-permit built in)
wallet.CreateEscrow(ctx, payee, amount, ...EscrowOption)    // *Escrow (opts: WithMemo, WithEscrowPermit, WithMilestones)
wallet.ClaimStart(ctx, escrowID)                            // *Escrow
wallet.ReleaseEscrow(ctx, escrowID, milestoneIDs...)        // *Escrow
wallet.CancelEscrow(ctx, escrowID)                          // *Escrow
wallet.GetEscrow(ctx, escrowID)                             // *Escrow

// Tabs (auto-permit built in)
wallet.CreateTab(ctx, provider, limit, perUnit, ...TabOption) // *Tab (opts: WithTabPermit, WithTabExpiry)
wallet.ChargeTab(ctx, tabID, amount, cumulative, callCount, providerSig) // *TabCharge
wallet.CloseTab(ctx, tabID, ...CloseTabOption)              // *Tab (opts: WithCloseTabAmount, WithCloseTabSig)
wallet.GetTab(ctx, tabID)                                   // *Tab

// Streams (auto-permit built in)
wallet.CreateStream(ctx, payee, rate, maxTotal, ...StreamOption) // *Stream (opts: WithStreamPermit)
wallet.CloseStream(ctx, streamID)                           // *Stream
wallet.WithdrawStream(ctx, streamID)                        // *Transaction

// Bounties (auto-permit built in)
wallet.CreateBounty(ctx, amount, task, deadline, ...BountyOption) // *Bounty (opts: WithBountyPermit, WithBountyMaxAttempts)
wallet.SubmitBounty(ctx, bountyID, evidenceHash)            // *BountySubmission
wallet.AwardBounty(ctx, bountyID, submissionID)             // *Bounty
wallet.ListBounties(ctx, opts)                              // []Bounty

// Deposits (auto-permit built in)
wallet.PlaceDeposit(ctx, provider, amount, expires, ...DepositOption) // *Deposit (opts: WithDepositPermit)
wallet.ReturnDeposit(ctx, depositID)                        // *Transaction

// Status & analytics
wallet.SpendingSummary(ctx, period)                         // *SpendingSummary
wallet.RemainingBudget(ctx)                                 // *Budget
wallet.History(ctx, opts)                                   // *TransactionList
wallet.Reputation(ctx, address)                             // *Reputation

// Webhooks
wallet.RegisterWebhook(ctx, url, events, chains...)         // *Webhook

// Operator links (options: WithLinkMessages([]string), WithAgentName(string))
wallet.CreateFundLink(ctx, ...LinkOption)                    // *LinkResponse
wallet.CreateWithdrawLink(ctx, ...LinkOption)                // *LinkResponse

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

## Advanced: Manual Permits

All payment methods auto-sign an EIP-2612 permit internally. If you need manual control
(e.g., custom deadline, pre-signed permit from another signer), use `SignPermit` and pass
the result via the `With*Permit` option:

```go
// Sign a permit manually with a custom deadline (2 hours)
deadline := time.Now().Unix() + 7200
permit, err := wallet.SignPermit(ctx, routerAddress, 5.0, deadline)

// Pass it explicitly — skips auto-permit
tx, err := wallet.Pay(ctx, "0xRecipient...", decimal.NewFromFloat(5.0),
    remitmd.WithPayPermit(permit))
```

Permit nonces are fetched from the API automatically. No RPC configuration needed.
