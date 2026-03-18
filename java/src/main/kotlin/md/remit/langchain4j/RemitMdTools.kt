package md.remit.langchain4j

import dev.langchain4j.agent.tool.Tool
import dev.langchain4j.agent.tool.P
import md.remit.Wallet
import md.remit.models.*
import java.math.BigDecimal

/**
 * LangChain4j tool class for remit.md payments.
 *
 * Annotate with `@Tool` — LangChain4j automatically discovers and calls
 * these methods based on the agent's natural language instructions.
 *
 * ```kotlin
 * val tools = RemitMdTools(wallet)
 * val agent = AiServices.builder(PaymentAgent::class.java)
 *     .chatLanguageModel(model)
 *     .tools(tools)
 *     .build()
 * ```
 *
 * The agent can then say:
 * > "Pay 3 USDC to 0xContractor for writing the report"
 * and LangChain4j will call [pay] automatically.
 */
class RemitMdTools(private val wallet: Wallet) {

    @Tool("Send a direct USDC payment to an Ethereum address. Use for immediate, irreversible transfers.")
    fun pay(
        @P("Recipient Ethereum address (0x-prefixed, 42 chars)") to: String,
        @P("USDC amount (e.g., 1.50)") amount: BigDecimal,
        @P("Optional memo for the payment") memo: String?
    ): String {
        val tx = wallet.pay(to, amount, memo)
        return "Payment sent: ${tx.id} — ${tx.amount} USDC to ${tx.to}"
    }

    @Tool("Create a funded escrow for work to be done. Funds locked until you release or it expires.")
    fun createEscrow(
        @P("Payee address (the worker's address)") payee: String,
        @P("USDC amount to lock") amount: BigDecimal,
        @P("Description of the work") memo: String?
    ): String {
        val e = wallet.createEscrow(payee, amount, memo, null)
        return "Escrow created: ${e.id} — ${e.amount} USDC for ${e.payee} (status: ${e.status})"
    }

    @Tool("Release escrow funds to the payee after verifying their work is satisfactory.")
    fun releaseEscrow(@P("Escrow ID to release") escrowId: String): String {
        val tx = wallet.releaseEscrow(escrowId)
        return "Escrow released: ${tx.id} — ${tx.amount} USDC sent to ${tx.to}"
    }

    @Tool("Cancel an escrow and return funds to yourself if work was not completed.")
    fun cancelEscrow(@P("Escrow ID to cancel") escrowId: String): String {
        val tx = wallet.cancelEscrow(escrowId)
        return "Escrow cancelled: ${escrowId} — ${tx.amount} USDC returned"
    }

    @Tool("Check the status of an existing escrow.")
    fun getEscrow(@P("Escrow ID to look up") escrowId: String): String {
        val e = wallet.getEscrow(escrowId)
        return "Escrow ${e.id}: ${e.status} — ${e.amount} USDC, payee: ${e.payee}"
    }

    @Tool("Open a payment channel (tab) for micro-payments to a service. Cheaper for high-frequency calls.")
    fun openTab(
        @P("Service provider address") provider: String,
        @P("Maximum USDC allowed on this tab") limitAmount: BigDecimal,
        @P("Price per unit of work") perUnit: BigDecimal
    ): String {
        val t = wallet.createTab(provider, limitAmount, perUnit)
        return "Tab opened: ${t.id} — limit ${t.limitAmount} USDC with ${t.provider}"
    }

    @Tool("Charge a tab with a provider signature. Use after each API call or micro-service invocation.")
    fun chargeTab(
        @P("Tab ID to charge") tabId: String,
        @P("USDC amount to charge") amount: BigDecimal,
        @P("Cumulative amount charged") cumulative: BigDecimal,
        @P("Call count") callCount: Int,
        @P("Provider EIP-712 signature") providerSig: String
    ): String {
        val c = wallet.chargeTab(tabId, amount, cumulative, callCount, providerSig)
        return "Tab charged: ${c.amount} USDC (cumulative: ${c.cumulative} USDC)"
    }

    @Tool("Close a tab and settle all charges on-chain.")
    fun closeTab(
        @P("Tab ID to close") tabId: String,
        @P("Final charged amount") finalAmount: BigDecimal,
        @P("Provider EIP-712 signature") providerSig: String
    ): String {
        val t = wallet.closeTab(tabId, finalAmount, providerSig)
        return "Tab closed: ${t.totalCharged} USDC finalized on-chain (tx: ${t.closedTxHash})"
    }

    @Tool("Post a USDC bounty that any agent can claim by completing the task.")
    fun postBounty(
        @P("USDC amount for the bounty") amount: BigDecimal,
        @P("Clear description of the task and acceptance criteria") taskDescription: String,
        @P("Deadline as unix timestamp") deadline: Long
    ): String {
        val b = wallet.createBounty(amount, taskDescription, deadline)
        return "Bounty posted: ${b.id} — ${b.amount} USDC for: ${b.taskDescription}"
    }

    @Tool("Award a bounty to a specific submission.")
    fun awardBounty(
        @P("Bounty ID to award") bountyId: String,
        @P("Submission ID to award") submissionId: Int
    ): String {
        val b = wallet.awardBounty(bountyId, submissionId)
        return "Bounty awarded: ${b.amount} USDC (status: ${b.status})"
    }

    @Tool("Check your current USDC wallet balance.")
    fun checkBalance(): String {
        val b = wallet.balance()
        return "Balance: ${b.usdc} USDC (chain: ${b.chainId})"
    }

    @Tool("Look up the reputation score for an Ethereum address. Higher = more trustworthy.")
    fun checkReputation(@P("Ethereum address to check") address: String): String {
        val r = wallet.reputation(address)
        return "Reputation for ${address}: score ${r.score}/1000, ${r.transactionCount} transactions"
    }
}
