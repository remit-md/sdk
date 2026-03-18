package md.remit

import md.remit.models.*
import java.math.BigDecimal
import java.time.Duration

/**
 * Kotlin extension functions for [Wallet].
 *
 * Provides idiomatic Kotlin DSL for all payment operations:
 *
 * ```kotlin
 * val wallet = RemitMd.fromEnv()
 *
 * // Direct payment
 * wallet.pay("0xRecipient...", 1.50.usdc)
 *
 * // Escrow with DSL
 * wallet.escrow("0xRecipient...", 5.00.usdc) {
 *     memo = "Task completion payment"
 *     expiresIn = Duration.ofDays(7)
 * }
 * ```
 */

/** Converts a Double to USDC amount as BigDecimal. */
val Double.usdc: BigDecimal get() = BigDecimal.valueOf(this)

/** Converts an Int to USDC amount as BigDecimal. */
val Int.usdc: BigDecimal get() = BigDecimal(this)

/** Converts a Long to USDC amount as BigDecimal. */
val Long.usdc: BigDecimal get() = BigDecimal(this)

/** Converts a String to USDC amount as BigDecimal. */
val String.usdc: BigDecimal get() = BigDecimal(this)

// ─── Escrow DSL ───────────────────────────────────────────────────────────────

/** Configuration block for [Wallet.createEscrow]. */
class EscrowConfig {
    var memo: String? = null
    var expiresIn: Duration? = null
    var milestones: List<Escrow.Milestone>? = null
    var splits: List<Escrow.Split>? = null
}

/**
 * Creates an escrow with a Kotlin DSL configuration block.
 *
 * ```kotlin
 * wallet.escrow("0xPayee...", 10.00.usdc) {
 *     memo = "Design work"
 *     expiresIn = Duration.ofDays(14)
 * }
 * ```
 */
fun Wallet.escrow(payee: String, amount: BigDecimal, configure: EscrowConfig.() -> Unit = {}): Escrow {
    val cfg = EscrowConfig().apply(configure)
    return createEscrow(payee, amount, cfg.memo, cfg.expiresIn, cfg.milestones, cfg.splits)
}

// ─── Tab DSL ──────────────────────────────────────────────────────────────────

/** Configuration block for [Wallet.createTab]. */
class TabConfig {
    var perUnit: BigDecimal = BigDecimal.valueOf(0.1)
    var expiresInSeconds: Int = 86400
}

/**
 * Opens a payment channel with a Kotlin DSL configuration block.
 *
 * ```kotlin
 * val tab = wallet.tab("0xService...", 50.00.usdc) {
 *     perUnit = 0.05.usdc
 *     expiresInSeconds = 3600
 * }
 * ```
 */
fun Wallet.tab(provider: String, limitAmount: BigDecimal, configure: TabConfig.() -> Unit = {}): Tab {
    val cfg = TabConfig().apply(configure)
    return createTab(provider, limitAmount, cfg.perUnit, cfg.expiresInSeconds)
}

// ─── Bounty DSL ───────────────────────────────────────────────────────────────

/** Configuration block for [Wallet.createBounty]. */
class BountyConfig {
    var deadline: Long = java.time.Instant.now().epochSecond + 86400
    var maxAttempts: Int = 10
}

/**
 * Posts a bounty with a Kotlin DSL configuration block.
 *
 * ```kotlin
 * val bounty = wallet.bounty(25.00.usdc, "Summarize this research paper") {
 *     deadline = Instant.now().epochSecond + 7200
 * }
 * ```
 */
fun Wallet.bounty(amount: BigDecimal, taskDescription: String, configure: BountyConfig.() -> Unit = {}): Bounty {
    val cfg = BountyConfig().apply(configure)
    return createBounty(amount, taskDescription, cfg.deadline, cfg.maxAttempts, null)
}

// ─── Suspension wrappers (coroutines-friendly) ────────────────────────────────
// If kotlin-coroutines is on the classpath, these functions run on IO dispatcher.
// Without coroutines they are regular extension functions.

/** Pays via coroutine (runs blocking HTTP on calling thread; wrap in withContext(Dispatchers.IO) as needed). */
suspend fun Wallet.payAsync(to: String, amount: BigDecimal, memo: String? = null) =
    pay(to, amount, memo)

suspend fun Wallet.balanceAsync() = balance()
