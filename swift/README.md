# remit.md Swift SDK

[![CI](https://github.com/remit-md/sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/remit-md/sdk/actions/workflows/ci.yml)

Universal payment protocol for AI agents — Swift 5.7+, macOS 12+, iOS 15+.

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
    privateKey: ProcessInfo.processInfo.environment["REMIT_PRIVATE_KEY"]!,
    chain: .base
)
let tx = try await wallet.pay(to: "0xAgent...", amount: 1.00)
print(tx.id, tx.status) // "tx_...", "confirmed"

// Environment-based (reads REMIT_PRIVATE_KEY + REMIT_CHAIN)
let wallet = try RemitWallet.fromEnvironment()
```

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
let tab = try await wallet.openTab(recipient: "0xService...", limit: 10.0)
_ = try await wallet.debitTab(id: tab.id, amount: 0.001, memo: "token 1")
_ = try await wallet.debitTab(id: tab.id, amount: 0.002, memo: "token 2")
let closed = try await wallet.closeTab(id: tab.id)
print("Total:", closed.spent, "USDC")
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
let deposit = try await wallet.lockDeposit(
    recipient: "0xOperator...", amount: 100.0, reason: "API access collateral"
)
```

## Analytics

```swift
let balance = try await wallet.balance()
let reputation = try await wallet.reputation()
let summary = try await wallet.spendingSummary()
let history = try await wallet.history()
let budget = try await wallet.budget()
```

## Error handling

All errors are `RemitError` with a machine-readable code, actionable message, and doc URL.

```swift
do {
    try await wallet.pay(to: "bad-address", amount: 1.0)
} catch let e as RemitError {
    print(e.code)    // "INVALID_ADDRESS"
    print(e.message) // "[INVALID_ADDRESS] expected 0x-prefixed 42-char hex string..."
    print(e.docURL)  // "https://remit.md/docs/api-reference/error-codes#invalid_address"
}
```

## Documentation

- [Swift quickstart](https://remit.md/docs/getting-started/quickstart-swift)
- [API reference](https://remit.md/docs/api-reference/swift-sdk)
- [Error codes](https://remit.md/docs/api-reference/error-codes)

## License

MIT — see [LICENSE](../../LICENSE)
