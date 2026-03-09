import md.remit.MockRemit
import md.remit.RemitMd
import md.remit.usdc

/**
 * Quick start example in Kotlin — uses Kotlin DSL extensions.
 *
 * For live API, replace mock.wallet() with:
 *   val wallet = RemitMd.fromEnv()
 */
fun main() {
    // ─── MockRemit for testing (zero network) ────────────────────────────────
    val mock = MockRemit()
    val wallet = mock.wallet()

    val recipient = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

    // Direct payment — Kotlin decimal extension
    val payment = wallet.pay(recipient, 1.50.usdc, "for the API call")
    println("Paid: ${payment.amount} USDC → ${payment.to}")

    // Escrow with Kotlin DSL
    val escrow = wallet.escrow(recipient, 5.00.usdc) {
        memo = "code review"
    }
    println("Escrow: ${escrow.id} (${escrow.status})")

    // Release after verifying work
    wallet.releaseEscrow(escrow.id)
    println("Released → $recipient")

    // Bounty with DSL
    val bounty = wallet.bounty(25.00.usdc, "Summarize the research paper") {
        // expiresIn = Duration.ofDays(3)
    }
    println("Bounty posted: ${bounty.id} — ${bounty.award} USDC")

    // Mock assertions
    println("Transactions: ${mock.transactionCount()}")
    println("Total paid: ${mock.totalPaidTo(recipient)} USDC")

    // ─── Live API ────────────────────────────────────────────────────────────
    // val live = RemitMd.fromEnv()
    // val live = RemitMd.withKey("0x...").chain("base").testnet(true).build()
}
