/// remit.md Swift SDK - Quickstart
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
        print("Paid:", tx.amount, "USDC ->", tx.to, "(tx:", tx.id + ")")

        // 2. Escrow - payment released only when conditions are met
        let escrow = try await wallet.createEscrow(
            recipient: recipient, amount: 25.0, conditions: "task complete"
        )
        let released = try await wallet.releaseEscrow(id: escrow.id)
        print("Escrow released:", released.id, "status:", released.status.rawValue)

        // 3. Metered tab - pay-as-you-go for micro-services
        let tab = try await wallet.openTab(provider: recipient, limitAmount: 10.0, perUnit: 0.01)
        _ = try await wallet.chargeTab(id: tab.id, amount: 0.01, cumulative: 0.01,
                                        callCount: 1, providerSig: "0xdead")
        _ = try await wallet.chargeTab(id: tab.id, amount: 0.02, cumulative: 0.03,
                                        callCount: 2, providerSig: "0xbeef")
        let closed = try await wallet.closeTab(id: tab.id, finalAmount: 0.03, providerSig: "0xfeed")
        print("Tab closed. Total:", closed.spent, "USDC")

        // 4. Streaming - per-second real-time payment
        let stream = try await wallet.startStream(payee: recipient, ratePerSecond: 0.0001, maxTotal: 5.0)
        print("Stream started:", stream.id, "at", stream.ratePerSecond, "USDC/s")
        let stopped = try await wallet.closeStream(id: stream.id)
        print("Stream stopped:", stopped.status.rawValue)

        // 5. Bounty - reward the first agent to complete a task
        let deadline = Int(Date().timeIntervalSince1970) + 3600
        let bounty = try await wallet.postBounty(amount: 5.0, taskDescription: "Summarize document",
                                                  deadline: deadline)
        let sub = try await wallet.submitBounty(id: bounty.id, evidenceHash: "0xdeadbeef")
        let awarded = try await wallet.awardBounty(id: bounty.id, submissionId: sub.id)
        print("Bounty awarded:", awarded.amount, "USDC, status:", awarded.status.rawValue)

        // 6. Security deposit
        let deposit = try await wallet.placeDeposit(
            provider: recipient, amount: 100.0, expiresIn: 3600
        )
        print("Deposit locked:", deposit.id, "status:", deposit.status.rawValue)
        let returned = try await wallet.returnDeposit(id: deposit.id)
        print("Deposit returned:", returned.id)

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
