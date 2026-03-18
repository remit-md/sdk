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
const wallet = new Wallet({ privateKey: "0x...", chain: "base-sepolia" });

// Get contract addresses (cached per session)
const contracts = await wallet.getContracts();

// Sign a permit (gasless USDC approval) and pay
const permit = await wallet.signPermit(contracts.router, 1.50);
const tx = await wallet.payDirect("0xRecipient...", 1.50, "inference fee", { permit });
console.log(tx.txHash);
```

## Payment Models

### Permits (Gasless USDC Approval)

Every payment that moves USDC requires on-chain approval. Use `signPermit()` to sign an EIP-2612 permit off-chain — no gas, no approve transaction.

```typescript
const contracts = await wallet.getContracts();

// signPermit(spender, amount, deadline?) — auto-fetches nonce from chain
const permit = await wallet.signPermit(contracts.router, 5.0);
```

The `spender` must match the contract handling the payment:
- Direct payment: `contracts.router`
- Escrow: `contracts.escrow`
- Tab: `contracts.tab`
- Stream: `contracts.stream`
- Bounty: `contracts.bounty`
- Deposit: `contracts.deposit`

### Direct Payment

```typescript
const permit = await wallet.signPermit(contracts.router, 5.0);
const tx = await wallet.payDirect("0xRecipient...", 5.0, "AI task", { permit });
```

### Escrow

```typescript
const permit = await wallet.signPermit(contracts.escrow, 100.0);
const escrow = await wallet.pay({
  to: "0xContractor...",
  amount: 100.0,
  memo: "Code review",
}, { permit });

// Work happens...
await wallet.releaseEscrow(escrow.id);  // pay the contractor
// or
await wallet.cancelEscrow(escrow.id);   // refund yourself
```

### Metered Tab (off-chain billing)

```typescript
const permit = await wallet.signPermit(contracts.tab, 50);
const tab = await wallet.openTab({
  to: "0xProvider...",
  limit: 50,
  perUnit: 0.003,
  permit,
});

// Provider debits the tab for each API call — zero gas, instant

// One on-chain settlement when done
await wallet.closeTab(tab.id);
```

### Payment Stream

```typescript
const permit = await wallet.signPermit(contracts.stream, 10);
const stream = await wallet.openStream({
  to: "0xWorker...",
  rate: 0.001, // USDC per second
  permit,
});

await wallet.closeStream(stream.id);
```

### Bounty

```typescript
const permit = await wallet.signPermit(contracts.bounty, 25);
const bounty = await wallet.postBounty({
  amount: 25,
  task: "Summarise top 10 EIPs of 2025",
  deadline: 1700000000,
  permit,
});

// Any agent can submit work; you decide the winner
await wallet.awardBounty(bounty.id, "0xWinner...");
```

### Security Deposit

```typescript
const permit = await wallet.signPermit(contracts.deposit, 100);
const deposit = await wallet.placeDeposit({
  to: "0xCounterpart...",
  amount: 100,
  expires: 86400, // 24 hours
  permit,
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
// Contract discovery (cached per session)
wallet.getContracts()                                    // Promise<ContractAddresses>

// Permits (gasless USDC approval)
wallet.signPermit(spender, amount, deadline?)            // Promise<PermitSignature>
wallet.signUsdcPermit({ spender, value, deadline, ... }) // Promise<PermitSignature>

// Direct payment
wallet.payDirect(to, amount, memo?, { permit? })         // Promise<Transaction>

// Escrow
wallet.pay(invoice, { permit? })                         // Promise<Escrow>
wallet.claimStart(invoiceId)                             // Promise<Transaction>
wallet.submitEvidence(invoiceId, uri, milestoneIndex?)   // Promise<Transaction>
wallet.releaseEscrow(invoiceId)                          // Promise<Transaction>
wallet.releaseMilestone(invoiceId, index)                // Promise<Transaction>
wallet.cancelEscrow(invoiceId)                           // Promise<Transaction>
wallet.getEscrow(invoiceId)                              // Promise<Escrow>

// Tabs
wallet.openTab({ to, limit, perUnit, expires?, permit? })    // Promise<Tab>
wallet.closeTab(tabId)                                       // Promise<Transaction>
wallet.getTab(tabId)                                         // Promise<Tab>

// Streams
wallet.openStream({ to, rate, maxDuration?, maxTotal?, permit? }) // Promise<Stream>
wallet.closeStream(streamId)                                      // Promise<Transaction>

// Bounties
wallet.postBounty({ amount, task, deadline, permit?, ... })  // Promise<Bounty>
wallet.submitBounty(bountyId, evidenceUri)                   // Promise<Transaction>
wallet.awardBounty(bountyId, winner)                         // Promise<Transaction>

// Deposits
wallet.placeDeposit({ to, amount, expires, permit? })    // Promise<Deposit>

// Status & analytics
wallet.status()                                          // Promise<WalletStatus>
wallet.balance()                                         // Promise<number>

// Webhooks
wallet.registerWebhook(url, events, chains?)             // Promise<Webhook>
wallet.listWebhooks()                                    // Promise<Webhook[]>
wallet.deleteWebhook(id)                                 // Promise<void>

// Operator links
wallet.createFundLink()                                  // Promise<LinkResponse>
wallet.createWithdrawLink()                              // Promise<LinkResponse>

// Testnet
wallet.mint(amount)                                      // Promise<{ tx_hash, balance }>
wallet.requestTestnetFunds()                             // Promise<Transaction> (deprecated)

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
