# remit.md TypeScript SDK

> [Skill MD](https://remit.md) · [Docs](https://remit.md/docs) · [Agent Spec](https://remit.md/agent.md)

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

const wallet = Wallet.fromEnv(); // REMITMD_KEY, REMITMD_CHAIN

const tx = await wallet.payDirect("0xRecipient...", 1.50, "inference fee");
console.log(tx.txHash);
```

That's it. USDC approval is handled automatically.

## Local Signer (Recommended)

The local signer delegates key management to `remit signer`, a localhost HTTP server that holds your encrypted key. Your agent only needs a URL and token — no private key in the environment.

```bash
export REMIT_SIGNER_URL=http://127.0.0.1:7402
export REMIT_SIGNER_TOKEN=rmit_sk_...
```

```typescript
// Explicit
const signer = await HttpSigner.create({ url, token });
const wallet = new Wallet({ signer });

// Or auto-detect from env (recommended)
const wallet = await Wallet.withSigner(); // reads REMIT_SIGNER_URL + REMIT_SIGNER_TOKEN
```

`Wallet.fromEnv()` detects signer credentials automatically. Priority: `REMIT_SIGNER_URL` > `OWS_WALLET_ID` > `REMITMD_KEY`.

## Secure Wallet with OWS

The [Open Wallet Standard](https://openwallet.sh) replaces raw private keys with encrypted local storage and policy-gated signing. Keys never leave the vault — the SDK signs through OWS's FFI layer.

### Setup

```bash
# Install OWS (or: curl -fsSL https://docs.openwallet.sh/install.sh | bash)
npm install -g @open-wallet-standard/core

# Create a wallet + policy + API key in one command
ows wallet create --name remit-my-agent
```

Or use the Remit CLI which does all of this automatically:

```bash
remit init  # creates wallet, chain-lock policy, API key, prints MCP config
```

### Usage

```typescript
import { Wallet } from "@remitmd/sdk";

// Auto-detects OWS_WALLET_ID, falls back to REMITMD_KEY
const wallet = await Wallet.withOws();

// Everything works the same — payments, permits, x402
const tx = await wallet.payDirect("0xRecipient...", 1.50, "inference fee");
```

With explicit options:

```typescript
const wallet = await Wallet.withOws({
  walletId: "remit-my-agent",   // OWS wallet name or UUID
  owsApiKey: process.env.OWS_API_KEY,
  chain: "base",
});
```

### Environment Variables

| Variable | Purpose | Required |
|----------|---------|----------|
| `OWS_WALLET_ID` | OWS wallet name or UUID | Yes (for OWS path) |
| `OWS_API_KEY` | API key token for headless signing | Recommended |
| `REMITMD_CHAIN` | `"base"` or `"base-sepolia"` | No (defaults to `"base"`) |

Priority: explicit `signer` > explicit `privateKey` > `OWS_WALLET_ID` > `REMITMD_KEY`.

### Custom Signer

If you need a custom signing backend, implement the `Signer` interface:

```typescript
import type { Signer } from "@remitmd/sdk";

const mySigner: Signer = {
  getAddress: () => "0x...",
  signTypedData: async (domain, types, value) => "0x...",
};

const wallet = new Wallet({ signer: mySigner });
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
  maxTotal: 10,
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
// Contract discovery (cached per session)
wallet.getContracts()                                    // Promise<ContractAddresses>

// Direct payment
wallet.payDirect(to, amount, memo?)                      // Promise<Transaction>

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

// Webhooks
wallet.registerWebhook(url, events, chains?)             // Promise<Webhook>

// Operator links (optional: { messages?: string[], agentName?: string })
wallet.createFundLink(opts?)                             // Promise<LinkResponse>
wallet.createWithdrawLink(opts?)                         // Promise<LinkResponse>

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

All errors are structured with machine-readable codes and enriched details:

```typescript
try {
  await wallet.payDirect("0xRecipient...", 100.0);
} catch (err) {
  if (err instanceof RemitError) {
    console.log(err.code);    // "INSUFFICIENT_BALANCE"
    console.log(err.message); // "Insufficient USDC balance: have $5.00, need $100.00"
    // Enriched errors include actual numbers in details:
    // err.details = {required: "100.00", available: "5.00",
    //               required_units: 100000000, available_units: 5000000}
  }
}
```

## Chains

```typescript
new Wallet({ privateKey: key, chain: "base" })          // Base mainnet (default)
new Wallet({ privateKey: key, chain: "base-sepolia" })   // Base Sepolia testnet
```

## Advanced: Manual Permits

All payment methods auto-sign EIP-2612 USDC permits internally. If you need explicit control (custom spenders, pre-signed permits, multi-step workflows), you can sign and pass them manually:

```typescript
const contracts = await wallet.getContracts();
const permit = await wallet.signPermit(contracts.router, 5.0);
await wallet.payDirect("0xRecipient...", 5.0, "task", { permit });
```

The `spender` must match the contract handling the payment:

| Payment type | Spender |
|---|---|
| Direct | `contracts.router` |
| Escrow | `contracts.escrow` |
| Tab | `contracts.tab` |
| Stream | `contracts.stream` |
| Bounty | `contracts.bounty` |
| Deposit | `contracts.deposit` |

For lower-level control over nonce, deadline, and USDC address:

```typescript
const permit = await wallet.signUsdcPermit({
  spender: contracts.router,
  value: BigInt(5_000_000), // raw USDC base units
  deadline: Math.floor(Date.now() / 1000) + 3600,
  nonce: 0,
});
```

## License

MIT — see [LICENSE](LICENSE)

[Documentation](https://remit.md/docs) · [Protocol Spec](https://remit.md) · [GitHub](https://github.com/remit-md/sdk)
