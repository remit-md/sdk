# remit.md Swift SDK

> [Skill MD](https://remit.md) · [Docs](https://remit.md/docs) · [Agent Spec](https://remit.md/agent.md)

[![CI](https://github.com/remit-md/sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/remit-md/sdk/actions/workflows/ci.yml)

Universal payment protocol for AI agents - Swift 5.7+, macOS 12+, iOS 15+.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/remit-md/sdk.git", from: "0.1.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "RemitMd", package: "sdk"),
    ]),
]
```

## Quick start

```swift
import RemitMd

// Production
let wallet = try RemitWallet(
    privateKey: ProcessInfo.processInfo.environment["REMITMD_KEY"]!,
    chain: .base
)
let tx = try await wallet.pay(to: "0xAgent...", amount: 1.00)
print(tx.id, tx.status) // "tx_...", "confirmed"

// Environment-based (reads REMITMD_KEY + REMITMD_CHAIN)
let wallet = try RemitWallet.fromEnvironment()
```

## Local Signer (Recommended)

The local signer delegates key management to `remit signer`, a localhost HTTP server that holds your encrypted key. Your agent only needs a URL and token - no private key in the environment.

```bash
export REMIT_SIGNER_URL=http://127.0.0.1:7402
export REMIT_SIGNER_TOKEN=rmit_sk_...
```

```swift
// Explicit
let signer = try HttpSigner(url: "http://127.0.0.1:7402", token: "rmit_sk_...")
let wallet = RemitWallet(signer: signer, chain: .base)

// Or auto-detect from env (recommended)
let wallet = try RemitWallet.fromEnvironment() // detects REMIT_SIGNER_URL automatically
```

`RemitWallet.fromEnvironment()` detects signer credentials automatically. Priority: `REMIT_SIGNER_URL` > `REMITMD_KEY`.

## Testing (zero network calls)

```swift
import RemitMd
import XCTest

final class PaymentTests: XCTestCase {
    func testAgentPaysForService() async throws {
        let mock = MockRemit()
        let wallet = RemitWallet(mock: mock)
        mock.setBalance(100.0, for: mock.walletAddress)

        let tx = try await wallet.pay(to: "0xService...", amount: 0.003)
        XCTAssertEqual(tx.status, "confirmed")
        XCTAssertTrue(mock.wasPaid(address: "0xService..."))
        XCTAssertEqual(mock.totalPaid(to: "0xService..."), 0.003, accuracy: 0.0001)
    }
}
```

## Permits (Gasless USDC Approval)

All payment methods auto-sign EIP-2612 permits when no explicit permit is provided.
The wallet fetches the on-chain nonce, signs the permit, and includes it in the request automatically.

```swift
// Auto-permit (recommended) - just call the method, permit is handled internally
let tx = try await wallet.pay(to: "0xRecipient...", amount: 5.0)

// Manual permit - sign yourself if you need control over deadline/nonce
let contracts = try await wallet.getContracts()
let permit = try await wallet.signPermit(spender: contracts.router, amount: 5.0)
let tx = try await wallet.pay(to: "0xRecipient...", amount: 5.0, permit: permit)

// Low-level permit - full control over all parameters
let permit = try wallet.signUsdcPermit(
    spender: contracts.router,
    value: 5_000_000,    // base units (6 decimals)
    deadline: Int(Date().timeIntervalSince1970) + 3600,
    nonce: 0
)
```

Auto-permit works on: `pay`, `createEscrow`, `openTab`, `startStream`, `postBounty`, `placeDeposit`.

## Payment models

### Direct payment
```swift
let tx = try await wallet.pay(to: "0xRecipient...", amount: 0.10, memo: "API call")
```

### Escrow (conditional release)
```swift
let escrow = try await wallet.createEscrow(
    recipient: "0xRecipient...", amount: 25.0, conditions: "task complete"
)
// ... verify task ...
let released = try await wallet.releaseEscrow(id: escrow.id)
```

### Metered tab (pay-as-you-go)
```swift
let tab = try await wallet.openTab(provider: "0xService...", limitAmount: 10.0, perUnit: 0.001)

// Provider charges with EIP-712 signature
let sig = try RemitWallet.signTabCharge(
    signer: signer, tabContract: contracts.tab, tabId: tab.id,
    totalCharged: 1000000, callCount: 1
)
let charge = try await wallet.chargeTab(id: tab.id, amount: 0.001, cumulative: 0.001, callCount: 1, providerSig: sig)

let closed = try await wallet.closeTab(id: tab.id)
```

### Streaming (per-second payments)
```swift
let stream = try await wallet.startStream(
    recipient: "0xRecipient...", ratePerSecond: 0.0001
)
// ... later ...
let stopped = try await wallet.stopStream(id: stream.id)
```

### Bounty (task reward)
```swift
let bounty = try await wallet.postBounty(amount: 5.0, description: "Classify 1000 images")
// ... first agent to complete claims it ...
let awarded = try await wallet.awardBounty(id: bounty.id, winner: "0xWinner...")
```

### Security deposit
```swift
let deposit = try await wallet.placeDeposit(provider: "0xOperator...", amount: 100.0)
let returned = try await wallet.returnDeposit(id: deposit.id)
```

## Analytics

```swift
let balance = try await wallet.balance()
let reputation = try await wallet.reputation()
let summary = try await wallet.spendingSummary()
let history = try await wallet.history()
let budget = try await wallet.budget()
```

## Additional Methods

```swift
// Contract discovery (cached per session)
let contracts = try await wallet.getContracts()

// Webhooks
let wh = try await wallet.registerWebhook(url: "https://...", events: ["payment.received"])

// Operator links (optional: messages: [String]?, agentName: String?)
let fundLink = try await wallet.createFundLink()
let withdrawLink = try await wallet.createWithdrawLink(messages: ["Withdraw profits"], agentName: "my-agent")

// Testnet funding
let result = try await wallet.mint(amount: 100.0)  // $100 testnet USDC
```

## Error handling

All errors are `RemitError` with a machine-readable code, actionable message, and doc URL. Enriched errors include actual numbers:

```swift
do {
    try await wallet.pay(to: "0xRecipient...", amount: 100.0)
} catch let e as RemitError {
    print(e.code)    // "INSUFFICIENT_BALANCE"
    print(e.message) // "Insufficient USDC balance: have $5.00, need $100.00"
}
```

## Documentation

- [Swift quickstart](https://remit.md/docs/getting-started/quickstart-swift)
- [API reference](https://remit.md/docs/api-reference/swift-sdk)
- [Error codes](https://remit.md/docs/api-reference/error-codes)

## License

MIT - see [LICENSE](../../LICENSE)
