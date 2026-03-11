// Semantic Kernel integration for remit.md
// Adds remit.md as a plugin with KernelFunctions that agents can call.
//
// Usage:
//   var wallet = new Wallet(Environment.GetEnvironmentVariable("REMITMD_KEY")!);
//   kernel.ImportPluginFromObject(new RemitMdPlugin(wallet));

#if NET8_0_OR_GREATER

using System.ComponentModel;
using Microsoft.SemanticKernel;

namespace RemitMd.SemanticKernel;

/// <summary>
/// Semantic Kernel plugin that exposes remit.md payment operations as kernel functions.
/// Add this plugin to any SK-based agent to enable on-chain USDC payments.
///
/// <example>
/// <code>
/// var builder = Kernel.CreateBuilder();
/// builder.AddOpenAIChatCompletion("gpt-4o", apiKey);
///
/// var wallet = new Wallet(Environment.GetEnvironmentVariable("REMITMD_KEY")!);
/// builder.Plugins.AddFromObject(new RemitMdPlugin(wallet), "remitmd");
///
/// var kernel = builder.Build();
/// // The agent can now call remitmd-pay, remitmd-balance, etc.
/// </code>
/// </example>
/// </summary>
public sealed class RemitMdPlugin
{
    private readonly Wallet _wallet;

    /// <param name="wallet">The wallet used for all payment operations.</param>
    public RemitMdPlugin(Wallet wallet) => _wallet = wallet;

    /// <summary>Pays a USDC amount to a recipient Ethereum address.</summary>
    [KernelFunction("pay")]
    [Description("Send a USDC payment to an Ethereum address. " +
                 "Use this to pay for services, API calls, or data from other AI agents.")]
    public async Task<string> PayAsync(
        [Description("0x-prefixed Ethereum address of the recipient")] string recipient,
        [Description("Amount in USDC (e.g. 1.50 for $1.50)")] decimal amount,
        [Description("Optional memo describing the payment")] string memo = "",
        CancellationToken cancellationToken = default)
    {
        var tx = await _wallet.PayAsync(recipient, amount, memo, cancellationToken);
        return $"Payment sent. TX: {tx.TxHash}. Amount: {tx.Amount:F6} USDC. Fee: {tx.Fee:F6} USDC.";
    }

    /// <summary>Gets the current USDC balance of this agent's wallet.</summary>
    [KernelFunction("balance")]
    [Description("Get the current USDC balance of this agent's wallet. " +
                 "Check this before making payments to ensure sufficient funds.")]
    public async Task<string> BalanceAsync(CancellationToken cancellationToken = default)
    {
        var bal = await _wallet.BalanceAsync(cancellationToken);
        return $"Balance: {bal.Usdc:F6} USDC (address: {bal.Address})";
    }

    /// <summary>Gets the reputation score of an Ethereum address.</summary>
    [KernelFunction("reputation")]
    [Description("Get the payment reputation score of an Ethereum address (0-1000). " +
                 "Higher is better. Use to vet counterparties before sending large payments.")]
    public async Task<string> ReputationAsync(
        [Description("0x-prefixed Ethereum address to look up (leave empty for own address)")] string? address = null,
        CancellationToken cancellationToken = default)
    {
        var rep = await _wallet.ReputationAsync(address, cancellationToken);
        return $"Reputation for {rep.Address}: {rep.Score}/1000. " +
               $"Total paid: {rep.TotalPaid:F2} USDC. " +
               $"Transactions: {rep.TransactionCount}.";
    }

    /// <summary>Creates an escrow contract that holds funds until work is approved.</summary>
    [KernelFunction("create_escrow")]
    [Description("Create an escrow contract that holds USDC until the work is approved. " +
                 "Use for high-value tasks where you want to verify delivery before paying.")]
    public async Task<string> CreateEscrowAsync(
        [Description("0x-prefixed Ethereum address of the service provider")] string payee,
        [Description("Total escrow amount in USDC")] decimal amount,
        [Description("Description of the work or service")] string description = "",
        CancellationToken cancellationToken = default)
    {
        var escrow = await _wallet.CreateEscrowAsync(payee, amount, description, ct: cancellationToken);
        return $"Escrow created. ID: {escrow.Id}. " +
               $"Amount: {escrow.Amount:F6} USDC held for {escrow.Payee}. " +
               $"Status: {escrow.Status}.";
    }

    /// <summary>Releases escrow funds to the payee after approving the work.</summary>
    [KernelFunction("release_escrow")]
    [Description("Release escrow funds to the payee after verifying the work was completed. " +
                 "This is irreversible — verify the deliverable before releasing.")]
    public async Task<string> ReleaseEscrowAsync(
        [Description("Escrow ID to release")] string escrowId,
        CancellationToken cancellationToken = default)
    {
        var tx = await _wallet.ReleaseEscrowAsync(escrowId, cancellationToken);
        return $"Escrow {escrowId} released. TX: {tx.TxHash}. Amount: {tx.Amount:F6} USDC paid.";
    }

    /// <summary>Gets the current state of an escrow contract.</summary>
    [KernelFunction("get_escrow")]
    [Description("Get the current status and details of an escrow contract.")]
    public async Task<string> GetEscrowAsync(
        [Description("Escrow ID to look up")] string escrowId,
        CancellationToken cancellationToken = default)
    {
        var e = await _wallet.GetEscrowAsync(escrowId, cancellationToken);
        return $"Escrow {e.Id}: status={e.Status}, amount={e.Amount:F6} USDC, " +
               $"payee={e.Payee}, memo=\"{e.Memo}\"";
    }

    /// <summary>Opens a Tab for micro-payments to a counterpart.</summary>
    [KernelFunction("open_tab")]
    [Description("Open a Tab payment channel for efficient micro-payments. " +
                 "Tabs allow multiple small charges without per-transaction gas fees. " +
                 "Ideal for API usage billing and real-time services.")]
    public async Task<string> OpenTabAsync(
        [Description("0x-prefixed Ethereum address of the service accepting charges")] string counterpart,
        [Description("Maximum total spend limit in USDC")] decimal limit,
        CancellationToken cancellationToken = default)
    {
        var tab = await _wallet.CreateTabAsync(counterpart, limit, ct: cancellationToken);
        return $"Tab opened. ID: {tab.Id}. Limit: {tab.Limit:F6} USDC for {tab.Counterpart}.";
    }

    /// <summary>Charges an amount to an open Tab.</summary>
    [KernelFunction("debit_tab")]
    [Description("Charge an amount against an open Tab. Near-instant, gas-free. " +
                 "Use for per-request API billing, token usage fees, etc.")]
    public async Task<string> DebitTabAsync(
        [Description("Tab ID to charge")] string tabId,
        [Description("Amount in USDC to charge")] decimal amount,
        [Description("Description of what this charge is for")] string description = "",
        CancellationToken cancellationToken = default)
    {
        var debit = await _wallet.DebitTabAsync(tabId, amount, description, cancellationToken);
        return $"Tab {tabId} charged {amount:F6} USDC. Memo: \"{debit.Memo}\".";
    }

    /// <summary>Posts a bounty — a task with a USDC reward for completion.</summary>
    [KernelFunction("post_bounty")]
    [Description("Post a bounty offering a USDC reward to any agent that completes a task.")]
    public async Task<string> PostBountyAsync(
        [Description("USDC reward amount")] decimal award,
        [Description("Clear description of the task to be completed")] string description,
        CancellationToken cancellationToken = default)
    {
        var bounty = await _wallet.CreateBountyAsync(award, description, ct: cancellationToken);
        return $"Bounty posted. ID: {bounty.Id}. Award: {bounty.Award:F6} USDC for: \"{bounty.Description}\"";
    }

    /// <summary>Returns the spending summary for the current period.</summary>
    [KernelFunction("spending_summary")]
    [Description("Get a summary of spending for the current day, week, or month.")]
    public async Task<string> SpendingSummaryAsync(
        [Description("Time period: 'day', 'week', or 'month'")] string period = "day",
        CancellationToken cancellationToken = default)
    {
        var s = await _wallet.SpendingSummaryAsync(period, cancellationToken);
        return $"Spending ({s.Period}): {s.TotalSpent:F6} USDC in {s.TxCount} transactions. " +
               $"Fees paid: {s.TotalFees:F6} USDC.";
    }

    /// <summary>Returns remaining budget capacity under operator-set limits.</summary>
    [KernelFunction("remaining_budget")]
    [Description("Check remaining spending budget before making large payments. " +
                 "Returns daily and monthly remaining allowances set by the operator.")]
    public async Task<string> RemainingBudgetAsync(CancellationToken cancellationToken = default)
    {
        var b = await _wallet.RemainingBudgetAsync(cancellationToken);
        return $"Budget remaining: {b.DailyRemaining:F6} USDC today, " +
               $"{b.MonthlyRemaining:F6} USDC this month. " +
               $"Per-transaction limit: {b.PerTxLimit:F6} USDC.";
    }
}

#endif
