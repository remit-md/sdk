/// remit.md Swift SDK — Quickstart
/// All examples use MockRemit (no network, no real USDC).
/// Replace with RemitWallet(privateKey:) for production.

import Foundation
import RemitMd

@main
struct QuickstartExample {
    static func main() async throws {
        let mock = MockRemit()
        let wallet = RemitWallet(mock: mock)
        mock.setBalance(1000.0, for: mock.walletAddress)

        let recipient = "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B"

        // 1. Direct payment
        let tx = try await wallet.pay(to: recipient, amount: 0.003, memo: "API call #42")
        print("Paid:", tx.amount, "USDC →", tx.to, "(tx:", tx.id + ")")

        // 2. Escrow — payment released only when conditions are met
        let escrow = try await wallet.createEscrow(
            recipient: recipient, amount: 25.0, conditions: "task complete"
        )
        let released = try await wallet.releaseEscrow(id: escrow.id)
        print("Escrow released:", released.id, "status:", released.status.rawValue)

        // 3. Metered tab — pay-as-you-go for micro-services
        let tab = try await wallet.openTab(recipient: recipient, limit: 10.0)
        _ = try await wallet.debitTab(id: tab.id, amount: 0.01, memo: "token 1")
        _ = try await wallet.debitTab(id: tab.id, amount: 0.02, memo: "token 2")
        let closed = try await wallet.closeTab(id: tab.id)
        print("Tab closed. Total:", closed.spent, "USDC")

        // 4. Streaming — per-second real-time payment
        let stream = try await wallet.startStream(recipient: recipient, ratePerSecond: 0.0001)
        print("Stream started:", stream.id, "at", stream.ratePerSecond, "USDC/s")
        let stopped = try await wallet.stopStream(id: stream.id)
        print("Stream stopped:", stopped.status.rawValue)

        // 5. Bounty — reward the first agent to complete a task
        let bounty = try await wallet.postBounty(amount: 5.0, description: "Summarize document")
        let awarded = try await wallet.awardBounty(id: bounty.id, winner: recipient)
        print("Bounty awarded:", awarded.amount, "USDC to", awarded.winner!)

        // 6. Security deposit
        let deposit = try await wallet.lockDeposit(
            recipient: recipient, amount: 100.0, reason: "API collateral"
        )
        print("Deposit locked:", deposit.id, "status:", deposit.status.rawValue)

        // 7. Analytics
        let rep = try await wallet.reputation(of: recipient)
        print("Reputation score:", rep.score)

        let summary = try await wallet.spendingSummary()
        print("Total spent:", summary.totalSpent, "USDC")

        // MockRemit assertions
        print("\nMock assertions:")
        print("  wasPaid(recipient):", mock.wasPaid(address: recipient))
        print("  totalPaid:", mock.totalPaid(to: recipient))
        print("  transactionCount:", mock.transactionCount())
    }
}
