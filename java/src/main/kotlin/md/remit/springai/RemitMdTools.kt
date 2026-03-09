package md.remit.springai

import md.remit.Wallet
import md.remit.models.*
import org.springframework.ai.tool.annotation.Tool
import org.springframework.ai.tool.annotation.ToolParam
import java.math.BigDecimal

/**
 * Spring AI tool functions for remit.md payments.
 *
 * Register as a Spring bean and add to your ChatClient:
 *
 * ```kotlin
 * @Bean
 * fun remitTools(wallet: Wallet) = RemitMdTools(wallet)
 *
 * @Bean
 * fun chatClient(builder: ChatClient.Builder, tools: RemitMdTools) =
 *     builder.defaultTools(tools).build()
 * ```
 *
 * Your agent can then call payment tools naturally:
 * > "Pay 5 USDC to 0xRecipient for completing the task"
 */
class RemitMdTools(private val wallet: Wallet) {

    @Tool(name = "remitmd_pay", description = """
        Send a direct USDC payment to an Ethereum address.
        Use when you need to pay for a service, reward an agent, or transfer value.
        The payment is irreversible — use escrow if you need a refund option.
    """)
    fun pay(
        @ToolParam(description = "Ethereum address of the recipient (0x-prefixed, 42 characters)")
        to: String,
        @ToolParam(description = "Amount in USDC to send (e.g., 1.50 for $1.50)")
        amount: BigDecimal,
        @ToolParam(description = "Optional memo describing what this payment is for", required = false)
        memo: String?
    ): Transaction = wallet.pay(to, amount, memo)

    @Tool(name = "remitmd_create_escrow", description = """
        Create a funded escrow for work to be completed.
        Funds are locked until you call release_escrow or the escrow expires.
        Use when paying an agent to perform a task — release when the work is verified.
    """)
    fun createEscrow(
        @ToolParam(description = "Ethereum address of the payee (worker)")
        payee: String,
        @ToolParam(description = "Amount in USDC to lock in escrow")
        amount: BigDecimal,
        @ToolParam(description = "Description of the work being commissioned", required = false)
        memo: String?
    ): Escrow = wallet.createEscrow(payee, amount, memo, null)

    @Tool(name = "remitmd_release_escrow", description = """
        Release escrow funds to the payee after verifying their work is complete.
        Call this when you are satisfied with the deliverable.
    """)
    fun releaseEscrow(
        @ToolParam(description = "The escrow ID returned by create_escrow")
        escrowId: String
    ): Transaction = wallet.releaseEscrow(escrowId)

    @Tool(name = "remitmd_cancel_escrow", description = """
        Cancel an escrow and return funds to yourself.
        Use if the payee fails to deliver or you decide not to proceed.
    """)
    fun cancelEscrow(
        @ToolParam(description = "The escrow ID to cancel")
        escrowId: String
    ): Transaction = wallet.cancelEscrow(escrowId)

    @Tool(name = "remitmd_get_escrow", description = "Get the current status and details of an escrow.")
    fun getEscrow(
        @ToolParam(description = "The escrow ID to look up")
        escrowId: String
    ): Escrow = wallet.getEscrow(escrowId)

    @Tool(name = "remitmd_create_tab", description = """
        Open a payment channel for recurring micro-payments to a service.
        Cheaper than individual payments for high-frequency calls (e.g., API calls priced per use).
        Settle the tab when done to finalize charges on-chain.
    """)
    fun createTab(
        @ToolParam(description = "Ethereum address of the service provider")
        counterpart: String,
        @ToolParam(description = "Maximum USDC that can be charged through this tab")
        limit: BigDecimal
    ): Tab = wallet.createTab(counterpart, limit)

    @Tool(name = "remitmd_debit_tab", description = """
        Charge an amount against an open tab for a service call.
        Use after each API call or task to record the charge.
    """)
    fun debitTab(
        @ToolParam(description = "The tab ID to charge")
        tabId: String,
        @ToolParam(description = "Amount in USDC to charge")
        amount: BigDecimal,
        @ToolParam(description = "Description of what was charged for")
        memo: String
    ): TabDebit = wallet.debitTab(tabId, amount, memo)

    @Tool(name = "remitmd_settle_tab", description = "Close a tab and settle all charges on-chain.")
    fun settleTab(
        @ToolParam(description = "The tab ID to settle")
        tabId: String
    ): Transaction = wallet.settleTab(tabId)

    @Tool(name = "remitmd_create_bounty", description = """
        Post a USDC bounty for a task that any agent can claim.
        Any agent can submit work and you award the bounty to the best submission.
    """)
    fun createBounty(
        @ToolParam(description = "USDC amount awarded to the winner")
        award: BigDecimal,
        @ToolParam(description = "Clear description of the task and success criteria")
        description: String
    ): Bounty = wallet.createBounty(award, description)

    @Tool(name = "remitmd_award_bounty", description = "Award a bounty to the agent who completed the task.")
    fun awardBounty(
        @ToolParam(description = "The bounty ID to award")
        bountyId: String,
        @ToolParam(description = "Ethereum address of the winner")
        winner: String
    ): Transaction = wallet.awardBounty(bountyId, winner)

    @Tool(name = "remitmd_balance", description = "Check your current USDC balance.")
    fun balance(): Balance = wallet.balance()

    @Tool(name = "remitmd_reputation", description = "Look up the on-chain reputation score for any address.")
    fun reputation(
        @ToolParam(description = "Ethereum address to look up")
        address: String
    ): Reputation = wallet.reputation(address)

    @Tool(name = "remitmd_spending_summary", description = """
        Get your spending analytics for a period.
        Useful for reporting to operators or managing budgets.
    """)
    fun spendingSummary(
        @ToolParam(description = "Period: 'day', 'week', 'month', or 'all'")
        period: String
    ): SpendingSummary = wallet.spendingSummary(period)
}
