# remit.md TypeScript SDK

Universal payment protocol for AI agents — TypeScript/Node.js client library.

[![CI](https://github.com/remit-md/sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/remit-md/sdk/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/@remitmd/sdk)](https://www.npmjs.com/package/@remitmd/sdk)

## Installation

```bash
npm install @remitmd/sdk
# or
pnpm add @remitmd/sdk
```

## Quickstart

```typescript
import { Wallet } from "@remitmd/sdk";

// From environment variables (REMITMD_KEY, REMITMD_CHAIN)
const wallet = Wallet.fromEnv();

// Or with explicit key
const wallet = new Wallet({ privateKey: "0x...", chain: "base" });

// Send 1.50 USDC
const tx = await wallet.payDirect("0xRecipient...", 1.50, "inference fee");
console.log(tx.txHash);
```

## Payment Models

### Direct Payment

```typescript
const tx = await wallet.payDirect("0xRecipient...", 5.0, "AI task");
```

### Escrow

```typescript
const escrow = await wallet.pay({
  to: "0xContractor...",
  amount: 100.0,
  memo: "Code review",
});

// Work happens...
await wallet.releaseEscrow(escrow.id);  // pay the contractor
// or
await wallet.cancelEscrow(escrow.id);   // refund yourself
```

### Metered Tab (off-chain billing)

```typescript
const tab = await wallet.openTab({
  to: "0xProvider...",
  limit: 50,
  perUnit: 0.003,
});

// Provider debits the tab for each API call — zero gas, instant

// One on-chain settlement when done
await wallet.closeTab(tab.id);
```

### Payment Stream

```typescript
const stream = await wallet.openStream({
  to: "0xWorker...",
  rate: 0.001, // USDC per second
});

await wallet.closeStream(stream.id);
```

### Bounty

```typescript
const bounty = await wallet.postBounty({
  amount: 25,
  task: "Summarise top 10 EIPs of 2025",
  deadline: 1700000000,
});

// Any agent can submit work; you decide the winner
await wallet.awardBounty(bounty.id, "0xWinner...");
```

### Security Deposit

```typescript
const deposit = await wallet.placeDeposit({
  to: "0xCounterpart...",
  amount: 100,
  expires: 86400, // 24 hours
});
```

## Testing with MockRemit

MockRemit gives you a zero-network, zero-latency test double. No API key needed.

```typescript
import { MockRemit } from "@remitmd/sdk/testing";

const mock = new MockRemit();
const wallet = mock.wallet("0xAgent...");

const tx = await wallet.payDirect("0xProvider...", 0.003);
console.log(mock.wasPaid("0xProvider...", 0.003)); // true
```

## All Methods

```typescript
// Direct payment
wallet.payDirect(to, amount, memo?)                     // Promise<Transaction>

// Escrow
wallet.pay(invoice)                                      // Promise<Escrow>
wallet.claimStart(invoiceId)                             // Promise<Transaction>
wallet.submitEvidence(invoiceId, uri, milestoneIndex?)   // Promise<Transaction>
wallet.releaseEscrow(invoiceId)                          // Promise<Transaction>
wallet.releaseMilestone(invoiceId, index)                // Promise<Transaction>
wallet.cancelEscrow(invoiceId)                           // Promise<Transaction>
wallet.getEscrow(invoiceId)                              // Promise<Escrow>

// Tabs
wallet.openTab({ to, limit, perUnit, expires? })         // Promise<Tab>
wallet.closeTab(tabId)                                   // Promise<Transaction>
wallet.getTab(tabId)                                     // Promise<Tab>

// Streams
wallet.openStream({ to, rate, maxDuration?, maxTotal? }) // Promise<Stream>
wallet.closeStream(streamId)                             // Promise<Transaction>

// Bounties
wallet.postBounty({ amount, task, deadline, ... })       // Promise<Bounty>
wallet.submitBounty(bountyId, evidenceUri)               // Promise<Transaction>
wallet.awardBounty(bountyId, winner)                     // Promise<Transaction>

// Deposits
wallet.placeDeposit({ to, amount, expires })             // Promise<Deposit>

// Status & analytics
wallet.status()                                          // Promise<WalletStatus>
wallet.balance()                                         // Promise<number>

// Events
wallet.getEvents(wallet, since?)                         // Promise<RemitEvent[]>
wallet.on(event, callback)                               // void (polling)

// Webhooks
wallet.registerWebhook(url, events, chains?)             // Promise<Webhook>

// Operator links
wallet.createFundLink()                                  // Promise<LinkResponse>
wallet.createWithdrawLink()                              // Promise<LinkResponse>

// Testnet
wallet.requestTestnetFunds()                             // Promise<Transaction>

// x402 (HTTP 402 auto-pay)
wallet.x402Fetch(url, maxAutoPayUsdc?, init?)            // Promise<Response>
```

## x402 Support

The SDK has built-in support for the x402 HTTP payment protocol:

```typescript
// Auto-pay any 402 response up to 0.10 USDC
const response = await wallet.x402Fetch("https://api.example.com/data", 0.10);
const data = await response.json();
```

## Error Handling

All errors are structured with machine-readable codes:

```typescript
try {
  await wallet.payDirect("invalid", 1.0);
} catch (err) {
  if (err instanceof RemitError) {
    console.log(err.code);    // "INVALID_ADDRESS"
    console.log(err.message); // Human-readable description
  }
}
```

## Chains

```typescript
new Wallet({ privateKey: key, chain: "base" })          // Base mainnet (default)
new Wallet({ privateKey: key, chain: "base-sepolia" })   // Base Sepolia testnet
```

## License

MIT — see [LICENSE](LICENSE)

[Documentation](https://remit.md/docs) · [Protocol Spec](https://remit.md) · [GitHub](https://github.com/remit-md/sdk)
