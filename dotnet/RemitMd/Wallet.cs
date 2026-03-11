namespace RemitMd;

/// <summary>
/// The primary remit.md client. Use this to send payments from an AI agent.
///
/// <example>
/// <code>
/// var wallet = new Wallet(Environment.GetEnvironmentVariable("REMITMD_KEY")!);
/// var tx = await wallet.PayAsync("0xRecipient", 1.50m);
/// </code>
/// </example>
/// </summary>
public sealed class Wallet
{
    private readonly IRemitTransport _transport;
    private readonly IRemitSigner _signer;
    private readonly long _chainId;
    private readonly string _chain;

    // Chain → API base URL map
    private static readonly Dictionary<string, (long ChainId, string ApiUrl)> Chains = new()
    {
        ["base"]               = (8453,  "https://api.remit.md"),
        ["base-sepolia"]       = (84532, "https://api-sepolia.remit.md"),
        ["arbitrum"]           = (42161, "https://api-arb.remit.md"),
        ["arbitrum-sepolia"]   = (421614,"https://api-arb-sepolia.remit.md"),
        ["optimism"]           = (10,    "https://api-op.remit.md"),
        ["optimism-sepolia"]   = (11155420,"https://api-op-sepolia.remit.md"),
    };

    // ─── Constructors ─────────────────────────────────────────────────────────

    /// <summary>
    /// Creates a Wallet from a hex-encoded private key.
    /// </summary>
    /// <param name="privateKeyHex">64-character hex private key (0x prefix optional).</param>
    /// <param name="chain">Target chain name: "base", "arbitrum", "optimism". Default: "base".</param>
    /// <param name="testnet">When true, targets the testnet variant of <paramref name="chain"/>.</param>
    /// <param name="baseUrl">Override the API base URL (useful for local or self-hosted setups).</param>
    public Wallet(string privateKeyHex, string chain = "base", bool testnet = false, string? baseUrl = null, string? routerAddress = null)
        : this(new PrivateKeySigner(privateKeyHex), chain, testnet, baseUrl, routerAddress)
    { }

    /// <summary>
    /// Creates a Wallet with a custom <see cref="IRemitSigner"/> (KMS, HSM, etc.).
    /// </summary>
    /// <param name="routerAddress">EIP-712 verifying contract address. Required for production use.</param>
    public Wallet(IRemitSigner signer, string chain = "base", bool testnet = false, string? baseUrl = null, string? routerAddress = null)
    {
        var key = testnet ? $"{chain}-sepolia" : chain;

        if (!Chains.TryGetValue(key, out var cc))
        {
            var valid = string.Join(", ", Chains.Keys.Where(k => !k.EndsWith("-sepolia")));
            throw new RemitError(ErrorCodes.InvalidChain,
                $"Unsupported chain: \"{chain}\". Valid chains: {valid}. " +
                $"For testnet, pass testnet: true.",
                new Dictionary<string, object> { ["chain"] = chain });
        }

        _signer = signer;
        _chainId = cc.ChainId;
        _chain = chain;
        _transport = new HttpTransport(signer, cc.ChainId, routerAddress ?? string.Empty, baseUrl ?? cc.ApiUrl);
    }

    /// <summary>
    /// Creates a Wallet from the standard environment variables:
    /// <c>REMITMD_KEY</c> (required), <c>REMITMD_CHAIN</c> (optional), <c>REMITMD_TESTNET</c> (optional),
    /// <c>REMITMD_ROUTER_ADDRESS</c> (optional).
    /// </summary>
    public static Wallet FromEnvironment()
    {
        var key = Environment.GetEnvironmentVariable("REMITMD_KEY")
            ?? throw new RemitError(ErrorCodes.InvalidPrivateKey,
                "REMITMD_KEY environment variable is not set. " +
                "Export your agent's private key: export REMITMD_KEY=0x...");

        var chain         = Environment.GetEnvironmentVariable("REMITMD_CHAIN") ?? "base";
        var testnet       = Environment.GetEnvironmentVariable("REMITMD_TESTNET") is "1" or "true";
        var routerAddress = Environment.GetEnvironmentVariable("REMITMD_ROUTER_ADDRESS");

        return new Wallet(new PrivateKeySigner(key), chain, testnet, null, routerAddress);
    }

    /// <summary>The agent's Ethereum address (derived from the private key).</summary>
    public string Address => _signer.Address;

    // ─── Internal constructor for MockRemit ───────────────────────────────────

    internal Wallet(IRemitTransport transport, IRemitSigner signer, long chainId)
    {
        _transport = transport;
        _signer = signer;
        _chainId = chainId;
        _chain = "base";
    }

    // ─── Direct payments ──────────────────────────────────────────────────────

    /// <summary>
    /// Sends a direct USDC payment to <paramref name="recipient"/>.
    /// Settles on-chain via the remit.md router contract.
    /// </summary>
    /// <param name="recipient">0x-prefixed Ethereum address of the payee.</param>
    /// <param name="amount">Payment amount in USDC (e.g. 1.50 for $1.50).</param>
    /// <param name="memo">Optional memo attached to the payment.</param>
    /// <param name="ct">Cancellation token.</param>
    public Task<Transaction> PayAsync(
        string recipient,
        decimal amount,
        string memo = "",
        CancellationToken ct = default)
    {
        ValidateAddress(recipient, nameof(recipient));
        ValidateAmount(amount);

        var nonce = Convert.ToHexString(
            System.Security.Cryptography.RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        return _transport.PostAsync<Transaction>("/api/v0/payments/direct", new
        {
            to        = recipient,
            amount    = amount.ToString("F6"),
            task      = memo,
            chain     = _chain,
            nonce     = nonce,
            signature = "0x",
        }, ct);
    }

    // ─── Balance & reputation ─────────────────────────────────────────────────

    /// <summary>Returns the current USDC balance for this wallet.</summary>
    public Task<Balance> BalanceAsync(CancellationToken ct = default) =>
        _transport.GetAsync<Balance>($"/api/v0/status/{Address}", ct);

    /// <summary>Returns the payment history for this wallet (newest first).</summary>
    /// <param name="page">Page number (1-based).</param>
    /// <param name="perPage">Results per page (max 100).</param>
    public Task<TransactionList> HistoryAsync(int page = 1, int perPage = 20, CancellationToken ct = default) =>
        _transport.GetAsync<TransactionList>($"/api/v0/invoices?page={page}&per_page={perPage}", ct);

    /// <summary>Returns the reputation score for any Ethereum address.</summary>
    /// <param name="address">Address to look up (defaults to this wallet's address).</param>
    public Task<Reputation> ReputationAsync(string? address = null, CancellationToken ct = default) =>
        _transport.GetAsync<Reputation>($"/api/v0/reputation/{address ?? Address}", ct);

    // ─── Escrow ───────────────────────────────────────────────────────────────

    /// <summary>Creates an escrow contract holding funds until work is approved.</summary>
    /// <param name="payee">Ethereum address of the service provider.</param>
    /// <param name="amount">Total escrow amount in USDC.</param>
    /// <param name="memo">Description of the work.</param>
    /// <param name="milestones">Optional milestone-based payment schedule.</param>
    /// <param name="splits">Optional multi-party splits.</param>
    /// <param name="expiresAt">Optional expiry date for the escrow.</param>
    public Task<Escrow> CreateEscrowAsync(
        string payee,
        decimal amount,
        string memo = "",
        IEnumerable<Milestone>? milestones = null,
        IEnumerable<Split>? splits = null,
        DateTimeOffset? expiresAt = null,
        CancellationToken ct = default)
    {
        ValidateAddress(payee, nameof(payee));
        ValidateAmount(amount);

        return _transport.PostAsync<Escrow>("/api/v0/escrows", new
        {
            payee,
            amount      = amount.ToString("F6"),
            memo,
            milestones  = milestones?.ToList(),
            splits      = splits?.ToList(),
            expires_at  = expiresAt,
        }, ct);
    }

    /// <summary>Releases escrow funds to the payee after work is approved.</summary>
    public Task<Transaction> ReleaseEscrowAsync(string escrowId, CancellationToken ct = default) =>
        _transport.PostAsync<Transaction>($"/api/v0/escrows/{escrowId}/release", new { }, ct);

    /// <summary>Cancels an unfunded escrow and returns funds to the payer.</summary>
    public Task<Transaction> CancelEscrowAsync(string escrowId, CancellationToken ct = default) =>
        _transport.PostAsync<Transaction>($"/api/v0/escrows/{escrowId}/cancel", new { }, ct);

    /// <summary>Retrieves the current state of an escrow.</summary>
    public Task<Escrow> GetEscrowAsync(string escrowId, CancellationToken ct = default) =>
        _transport.GetAsync<Escrow>($"/api/v0/escrows/{escrowId}", ct);

    // ─── Tab (micro-payment channel) ──────────────────────────────────────────

    /// <summary>Opens a Tab — an off-chain payment channel for micro-payments.</summary>
    /// <param name="counterpart">Address of the service accepting Tab debits.</param>
    /// <param name="limit">Maximum USDC spend limit for this Tab.</param>
    /// <param name="closesAt">Optional expiry date.</param>
    public Task<Tab> CreateTabAsync(
        string counterpart,
        decimal limit,
        DateTimeOffset? closesAt = null,
        CancellationToken ct = default)
    {
        ValidateAddress(counterpart, nameof(counterpart));
        ValidateAmount(limit);

        return _transport.PostAsync<Tab>("/api/v0/tabs", new
        {
            counterpart,
            limit      = limit.ToString("F6"),
            closes_at  = closesAt,
        }, ct);
    }

    /// <summary>Charges an amount against an open Tab (near-zero latency, gas-free).</summary>
    public Task<TabDebit> DebitTabAsync(string tabId, decimal amount, string memo = "", CancellationToken ct = default)
    {
        ValidateAmount(amount);
        return _transport.PostAsync<TabDebit>($"/api/v0/tabs/{tabId}/charge", new
        {
            amount = amount.ToString("F6"),
            memo,
        }, ct);
    }

    /// <summary>Settles a Tab on-chain, finalizing all debits.</summary>
    public Task<Transaction> SettleTabAsync(string tabId, CancellationToken ct = default) =>
        _transport.PostAsync<Transaction>($"/api/v0/tabs/{tabId}/close", new { }, ct);

    // ─── Stream (time-based payments) ─────────────────────────────────────────

    /// <summary>
    /// Creates a payment stream — funds flow per-second to the recipient.
    /// Ideal for API usage billing, subscriptions, and real-time service fees.
    /// </summary>
    /// <param name="recipient">Address receiving the stream.</param>
    /// <param name="ratePerSecond">USDC per second (e.g. 0.000277m = $1/hour).</param>
    /// <param name="deposit">Up-front USDC deposited to back the stream.</param>
    public Task<Stream> CreateStreamAsync(
        string recipient,
        decimal ratePerSecond,
        decimal deposit,
        CancellationToken ct = default)
    {
        ValidateAddress(recipient, nameof(recipient));
        ValidateAmount(ratePerSecond, "ratePerSecond");
        ValidateAmount(deposit, "deposit");

        return _transport.PostAsync<Stream>("/api/v0/streams", new
        {
            recipient,
            rate_per_sec = ratePerSecond.ToString("F9"),
            deposit      = deposit.ToString("F6"),
        }, ct);
    }

    /// <summary>Withdraws accrued streaming funds to the recipient.</summary>
    public Task<Transaction> WithdrawStreamAsync(string streamId, CancellationToken ct = default) =>
        _transport.PostAsync<Transaction>($"/api/v0/streams/{streamId}/withdraw", new { }, ct);

    // ─── Bounty ───────────────────────────────────────────────────────────────

    /// <summary>Posts a bounty — a task with a USDC reward for completion.</summary>
    /// <param name="award">USDC reward amount.</param>
    /// <param name="description">Human (and agent) readable task description.</param>
    /// <param name="expiresAt">Optional expiry date.</param>
    public Task<Bounty> CreateBountyAsync(
        decimal award,
        string description,
        DateTimeOffset? expiresAt = null,
        CancellationToken ct = default)
    {
        ValidateAmount(award, "award");
        return _transport.PostAsync<Bounty>("/api/v0/bounties", new
        {
            award      = award.ToString("F6"),
            description,
            expires_at = expiresAt,
        }, ct);
    }

    /// <summary>Awards a bounty to the winning agent address.</summary>
    public Task<Transaction> AwardBountyAsync(string bountyId, string winner, CancellationToken ct = default)
    {
        ValidateAddress(winner, nameof(winner));
        return _transport.PostAsync<Transaction>($"/api/v0/bounties/{bountyId}/award", new { winner }, ct);
    }

    // ─── Deposit (security collateral) ────────────────────────────────────────

    /// <summary>Locks a security deposit held as collateral for a service agreement.</summary>
    public Task<Deposit> LockDepositAsync(
        string beneficiary,
        decimal amount,
        DateTimeOffset? expiresAt = null,
        CancellationToken ct = default)
    {
        ValidateAddress(beneficiary, nameof(beneficiary));
        ValidateAmount(amount);
        return _transport.PostAsync<Deposit>("/api/v0/deposits", new
        {
            beneficiary,
            amount     = amount.ToString("F6"),
            expires_at = expiresAt,
        }, ct);
    }

    // ─── Analytics & budget ───────────────────────────────────────────────────

    /// <summary>Returns spending analytics for the given period.</summary>
    /// <param name="period">"day", "week", or "month".</param>
    public Task<SpendingSummary> SpendingSummaryAsync(string period = "day", CancellationToken ct = default) =>
        _transport.GetAsync<SpendingSummary>($"/api/v0/invoices?period={period}", ct);

    /// <summary>Returns remaining spending capacity under operator-set budget limits.</summary>
    public Task<Budget> RemainingBudgetAsync(CancellationToken ct = default) =>
        _transport.GetAsync<Budget>($"/api/v0/status/{Address}", ct);

    /// <summary>Proposes a payment intent for negotiation with a counterpart.</summary>
    public Task<Intent> ProposeIntentAsync(
        string to,
        decimal amount,
        string type = "direct",
        CancellationToken ct = default)
    {
        ValidateAddress(to, nameof(to));
        ValidateAmount(amount);
        return _transport.PostAsync<Intent>("/api/v0/invoices", new
        {
            to,
            amount = amount.ToString("F6"),
            type,
        }, ct);
    }

    // ─── Validation helpers ───────────────────────────────────────────────────

    private static void ValidateAddress(string address, string paramName)
    {
        if (string.IsNullOrWhiteSpace(address) ||
            !address.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ||
            address.Length != 42)
        {
            throw new RemitError(ErrorCodes.InvalidAddress,
                $"Invalid {paramName}: expected 0x-prefixed 40-character hex address, got \"{address}\". " +
                "See https://remit.md/docs/addresses for details.",
                new Dictionary<string, object> { [paramName] = address });
        }
    }

    private static void ValidateAmount(decimal amount, string paramName = "amount")
    {
        if (amount <= 0)
            throw new RemitError(ErrorCodes.InvalidAmount,
                $"Invalid {paramName}: amount must be positive, got {amount}. " +
                "Minimum payment is 0.000001 USDC.",
                new Dictionary<string, object> { [paramName] = amount });
    }
}
