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
    private readonly string _chainKey;
    private readonly string _rpcUrl;
    private ContractAddresses? _cachedContracts;
    private static readonly HttpClient RpcClient = new() { Timeout = TimeSpan.FromSeconds(10) };

    // Chain → API base URL map
    private static readonly Dictionary<string, (long ChainId, string ApiUrl)> Chains = new()
    {
        ["base"]               = (8453,  "https://api.remit.md"),
        ["base-sepolia"]       = (84532, "https://api-sepolia.remit.md"),
    };

    // Chain → USDC contract address
    private static readonly Dictionary<string, string> UsdcAddresses = new()
    {
        ["base-sepolia"] = "0x142aD61B8d2edD6b3807D9266866D97C35Ee0317",
        ["base"]         = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        ["localhost"]    = "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    };

    // Chain → default public RPC URL
    private static readonly Dictionary<string, string> DefaultRpcUrls = new()
    {
        ["base-sepolia"] = "https://sepolia.base.org",
        ["base"]         = "https://mainnet.base.org",
        ["localhost"]    = "http://127.0.0.1:8545",
    };

    // ─── Constructors ─────────────────────────────────────────────────────────

    /// <summary>
    /// Creates a Wallet from a hex-encoded private key.
    /// </summary>
    /// <param name="privateKeyHex">64-character hex private key (0x prefix optional).</param>
    /// <param name="chain">Target chain name: "base". Default: "base".</param>
    /// <param name="testnet">When true, targets the testnet variant of <paramref name="chain"/>.</param>
    /// <param name="baseUrl">Override the API base URL (useful for local or self-hosted setups).</param>
    /// <param name="rpcUrl">JSON-RPC URL for on-chain reads (nonce fetching). Falls back to REMITMD_RPC_URL env var, then public defaults.</param>
    public Wallet(string privateKeyHex, string chain = "base", bool testnet = false, string? baseUrl = null, string? routerAddress = null, string? rpcUrl = null)
        : this(new PrivateKeySigner(privateKeyHex), chain, testnet, baseUrl, routerAddress, rpcUrl)
    { }

    /// <summary>
    /// Creates a Wallet with a custom <see cref="IRemitSigner"/> (KMS, HSM, etc.).
    /// </summary>
    /// <param name="routerAddress">EIP-712 verifying contract address. Required for production use.</param>
    /// <param name="rpcUrl">JSON-RPC URL for on-chain reads (nonce fetching). Falls back to REMITMD_RPC_URL env var, then public defaults.</param>
    public Wallet(IRemitSigner signer, string chain = "base", bool testnet = false, string? baseUrl = null, string? routerAddress = null, string? rpcUrl = null)
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
        _chainKey = key;
        _rpcUrl = rpcUrl
            ?? Environment.GetEnvironmentVariable("REMITMD_RPC_URL")
            ?? (DefaultRpcUrls.TryGetValue(key, out var defaultRpc) ? defaultRpc : DefaultRpcUrls["base-sepolia"]);
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
        var rpcUrl        = Environment.GetEnvironmentVariable("REMITMD_RPC_URL");

        return new Wallet(new PrivateKeySigner(key), chain, testnet, null, routerAddress, rpcUrl);
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
        _chainKey = "base";
        _rpcUrl = "";  // empty = mock mode, FetchUsdcNonceAsync returns 0
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
    public async Task<Transaction> PayAsync(
        string recipient,
        decimal amount,
        string memo = "",
        PermitSignature? permit = null,
        CancellationToken ct = default)
    {
        ValidateAddress(recipient, nameof(recipient));
        ValidateAmount(amount);

        permit ??= await AutoPermitAsync("router", amount);

        var nonce = Convert.ToHexString(
            System.Security.Cryptography.RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        var body = new Dictionary<string, object?>
        {
            ["to"]        = recipient,
            ["amount"]    = amount.ToString("F6"),
            ["task"]      = memo,
            ["chain"]     = _chain,
            ["nonce"]     = nonce,
            ["signature"] = "0x",
            ["permit"]    = permit,
        };
        return await _transport.PostAsync<Transaction>("/api/v0/payments/direct", body, ct);
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
    public async Task<Escrow> CreateEscrowAsync(
        string payee,
        decimal amount,
        string memo = "",
        IEnumerable<Milestone>? milestones = null,
        IEnumerable<Split>? splits = null,
        DateTimeOffset? expiresAt = null,
        PermitSignature? permit = null,
        CancellationToken ct = default)
    {
        ValidateAddress(payee, nameof(payee));
        ValidateAmount(amount);

        // Step 1: create invoice on server.
        var invoiceId = Guid.NewGuid().ToString("N")[..32];
        var nonce = Guid.NewGuid().ToString("N")[..32];
        var invoiceBody = new Dictionary<string, object?>
        {
            ["id"]         = invoiceId,
            ["chain"]      = _chain,
            ["from_agent"] = Address.ToLowerInvariant(),
            ["to_agent"]   = payee.ToLowerInvariant(),
            ["amount"]     = amount.ToString("F6"),
            ["type"]       = "escrow",
            ["task"]       = memo,
            ["nonce"]      = nonce,
            ["signature"]  = "0x",
        };
        if (expiresAt is not null)
        {
            var secs = (int)(expiresAt.Value - DateTimeOffset.UtcNow).TotalSeconds;
            invoiceBody["escrow_timeout"] = secs;
        }
        await _transport.PostAsync<object>("/api/v0/invoices", invoiceBody, ct);

        // Step 2: fund the escrow.
        permit ??= await AutoPermitAsync("escrow", amount);
        var escrowBody = new Dictionary<string, object?>
        {
            ["invoice_id"] = invoiceId,
            ["permit"]     = permit,
        };
        return await _transport.PostAsync<Escrow>("/api/v0/escrows", escrowBody, ct);
    }

    /// <summary>Releases escrow funds to the payee after work is approved.</summary>
    public Task<Transaction> ReleaseEscrowAsync(string escrowId, CancellationToken ct = default) =>
        _transport.PostAsync<Transaction>($"/api/v0/escrows/{escrowId}/release", new { }, ct);

    /// <summary>Cancels an unfunded escrow and returns funds to the payer.</summary>
    public Task<Transaction> CancelEscrowAsync(string escrowId, CancellationToken ct = default) =>
        _transport.PostAsync<Transaction>($"/api/v0/escrows/{escrowId}/cancel", new { }, ct);

    /// <summary>Signals the provider has started work on an escrow.</summary>
    public Task<Escrow> ClaimStartAsync(string escrowId, CancellationToken ct = default) =>
        _transport.PostAsync<Escrow>($"/api/v0/escrows/{escrowId}/claim-start", new { }, ct);

    /// <summary>Retrieves the current state of an escrow.</summary>
    public Task<Escrow> GetEscrowAsync(string escrowId, CancellationToken ct = default) =>
        _transport.GetAsync<Escrow>($"/api/v0/escrows/{escrowId}", ct);

    // ─── Tab (micro-payment channel) ──────────────────────────────────────────

    /// <summary>Opens a Tab — an off-chain payment channel for micro-payments.</summary>
    /// <param name="provider">Address of the service provider accepting Tab charges.</param>
    /// <param name="limitAmount">Maximum USDC spend limit for this Tab.</param>
    /// <param name="perUnit">Cost per unit/call in USDC.</param>
    /// <param name="expiresSecs">Seconds until Tab expires (default: 86400 = 24h).</param>
    public async Task<Tab> CreateTabAsync(
        string provider,
        decimal limitAmount,
        decimal perUnit,
        int expiresSecs = 86400,
        PermitSignature? permit = null,
        CancellationToken ct = default)
    {
        ValidateAddress(provider, nameof(provider));
        ValidateAmount(limitAmount, "limitAmount");

        permit ??= await AutoPermitAsync("tab", limitAmount);

        var expiry = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + expiresSecs;
        var body = new Dictionary<string, object?>
        {
            ["chain"]        = _chain,
            ["provider"]     = provider,
            ["limit_amount"] = limitAmount.ToString("F6"),
            ["per_unit"]     = perUnit.ToString("F6"),
            ["expiry"]       = expiry,
            ["permit"]       = permit,
        };
        return await _transport.PostAsync<Tab>("/api/v0/tabs", body, ct);
    }

    /// <summary>Charges an amount against an open Tab with a provider EIP-712 signature.</summary>
    /// <param name="tabId">Tab identifier.</param>
    /// <param name="amount">Amount for this individual charge.</param>
    /// <param name="cumulative">Cumulative total charged so far (including this charge).</param>
    /// <param name="callCount">Total number of charges made (including this one).</param>
    /// <param name="providerSig">EIP-712 TabCharge signature from the provider.</param>
    public Task<TabCharge> ChargeTabAsync(
        string tabId,
        decimal amount,
        decimal cumulative,
        int callCount,
        string providerSig,
        CancellationToken ct = default)
    {
        ValidateAmount(amount);
        return _transport.PostAsync<TabCharge>($"/api/v0/tabs/{tabId}/charge", new Dictionary<string, object?>
        {
            ["amount"]       = amount.ToString("F6"),
            ["cumulative"]   = cumulative.ToString("F6"),
            ["call_count"]   = callCount,
            ["provider_sig"] = providerSig,
        }, ct);
    }

    /// <summary>Closes a Tab on-chain, finalizing all charges.</summary>
    /// <param name="tabId">Tab identifier.</param>
    /// <param name="finalAmount">Final settled amount (0 to close without settlement).</param>
    /// <param name="providerSig">EIP-712 signature from the provider for the final amount.</param>
    public Task<Tab> CloseTabAsync(
        string tabId,
        decimal finalAmount = 0,
        string providerSig = "0x",
        CancellationToken ct = default) =>
        _transport.PostAsync<Tab>($"/api/v0/tabs/{tabId}/close", new Dictionary<string, object?>
        {
            ["final_amount"] = finalAmount.ToString("F6"),
            ["provider_sig"] = providerSig,
        }, ct);

    /// <summary>
    /// Signs an EIP-712 TabCharge message (provider-side).
    /// </summary>
    /// <param name="tabContract">Tab contract address (verifyingContract for the EIP-712 domain).</param>
    /// <param name="tabId">UUID of the tab (encoded as ASCII bytes padded to 32 bytes).</param>
    /// <param name="totalCharged">Cumulative charged amount in USDC base units (uint96).</param>
    /// <param name="callCount">Number of charges made (uint32).</param>
    /// <returns>0x-prefixed hex signature.</returns>
    public string SignTabCharge(string tabContract, string tabId, long totalCharged, int callCount)
    {
        // Encode tab UUID as bytes32: ASCII chars left-aligned, zero-padded to 32 bytes.
        var tabIdAscii = System.Text.Encoding.ASCII.GetBytes(tabId);
        var tabIdBytes32 = new byte[32];
        Buffer.BlockCopy(tabIdAscii, 0, tabIdBytes32, 0, Math.Min(tabIdAscii.Length, 32));

        // EIP-712 domain: RemitTab/1/<chainId>/<tabContract>
        var domainTypeHash = Eip712.Keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        var nameHash = Eip712.Keccak256("RemitTab");
        var versionHash = Eip712.Keccak256("1");
        var domainData = ConcatBytes(domainTypeHash, nameHash, versionHash,
            PadUint256Long(_chainId), PadAddressBytes(tabContract));
        var domainSep = Eip712.Keccak256(domainData);

        // TabCharge struct hash
        var typeHash = Eip712.Keccak256(
            "TabCharge(bytes32 tabId,uint96 totalCharged,uint32 callCount)");
        var structData = ConcatBytes(typeHash, tabIdBytes32,
            PadUint256Long(totalCharged), PadUint256Long(callCount));
        var structHash = Eip712.Keccak256(structData);

        // Final EIP-712 digest: "\x19\x01" || domainSeparator || structHash
        var payload = new byte[66];
        payload[0] = 0x19;
        payload[1] = 0x01;
        Buffer.BlockCopy(domainSep, 0, payload, 2, 32);
        Buffer.BlockCopy(structHash, 0, payload, 34, 32);
        var digest = Eip712.Keccak256(payload);

        return _signer.Sign(digest);
    }

    // ─── Stream (time-based payments) ─────────────────────────────────────────

    /// <summary>
    /// Creates a payment stream — funds flow per-second to the payee.
    /// Ideal for API usage billing, subscriptions, and real-time service fees.
    /// </summary>
    /// <param name="payee">Address receiving the stream.</param>
    /// <param name="ratePerSecond">USDC per second (e.g. 0.000277m = $1/hour).</param>
    /// <param name="maxTotal">Maximum total USDC the stream can pay out.</param>
    public async Task<Stream> CreateStreamAsync(
        string payee,
        decimal ratePerSecond,
        decimal maxTotal,
        PermitSignature? permit = null,
        CancellationToken ct = default)
    {
        ValidateAddress(payee, nameof(payee));
        ValidateAmount(ratePerSecond, "ratePerSecond");
        ValidateAmount(maxTotal, "maxTotal");

        permit ??= await AutoPermitAsync("stream", maxTotal);

        var body = new Dictionary<string, object?>
        {
            ["chain"]           = _chain,
            ["payee"]           = payee,
            ["rate_per_second"] = ratePerSecond.ToString("F9"),
            ["max_total"]       = maxTotal.ToString("F6"),
            ["permit"]          = permit,
        };
        return await _transport.PostAsync<Stream>("/api/v0/streams", body, ct);
    }

    /// <summary>Closes a stream, stopping further payments and settling on-chain.</summary>
    public Task<Transaction> CloseStreamAsync(string streamId, CancellationToken ct = default) =>
        _transport.PostAsync<Transaction>($"/api/v0/streams/{streamId}/close", new { }, ct);

    // ─── Bounty ───────────────────────────────────────────────────────────────

    /// <summary>Posts a bounty — a task with a USDC reward for completion.</summary>
    /// <param name="amount">USDC reward amount.</param>
    /// <param name="taskDescription">Human (and agent) readable task description.</param>
    /// <param name="deadlineSecs">Seconds until bounty deadline (default: 86400 = 24h).</param>
    /// <param name="maxAttempts">Maximum number of submission attempts (default: 10).</param>
    public async Task<Bounty> CreateBountyAsync(
        decimal amount,
        string taskDescription,
        int deadlineSecs = 86400,
        int maxAttempts = 10,
        PermitSignature? permit = null,
        CancellationToken ct = default)
    {
        ValidateAmount(amount);

        permit ??= await AutoPermitAsync("bounty", amount);

        var deadline = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + deadlineSecs;
        var body = new Dictionary<string, object?>
        {
            ["chain"]            = _chain,
            ["amount"]           = amount.ToString("F6"),
            ["task_description"] = taskDescription,
            ["deadline"]         = deadline,
            ["max_attempts"]     = maxAttempts,
            ["permit"]           = permit,
        };
        return await _transport.PostAsync<Bounty>("/api/v0/bounties", body, ct);
    }

    /// <summary>Submits evidence for a bounty.</summary>
    /// <param name="bountyId">Bounty identifier.</param>
    /// <param name="evidenceHash">Hash of the evidence being submitted.</param>
    /// <returns>A BountySubmission with the submission ID.</returns>
    public Task<BountySubmission> SubmitBountyAsync(
        string bountyId,
        string evidenceHash,
        CancellationToken ct = default) =>
        _transport.PostAsync<BountySubmission>($"/api/v0/bounties/{bountyId}/submit",
            new Dictionary<string, object?> { ["evidence_hash"] = evidenceHash }, ct);

    /// <summary>Awards a bounty to a specific submission (poster-only).</summary>
    /// <param name="bountyId">Bounty identifier.</param>
    /// <param name="submissionId">Integer ID of the winning submission.</param>
    public Task<Bounty> AwardBountyAsync(string bountyId, int submissionId, CancellationToken ct = default) =>
        _transport.PostAsync<Bounty>($"/api/v0/bounties/{bountyId}/award",
            new Dictionary<string, object?> { ["submission_id"] = submissionId }, ct);

    /// <summary>Lists bounties, optionally filtered by status, poster, or submitter.</summary>
    /// <param name="status">Filter by status (open, claimed, awarded, expired).</param>
    /// <param name="poster">Filter by poster wallet address.</param>
    /// <param name="submitter">Filter by submitter wallet address.</param>
    /// <param name="limit">Max results (default 20, max 100).</param>
    public async Task<Bounty[]> ListBountiesAsync(
        string? status = "open",
        string? poster = null,
        string? submitter = null,
        int limit = 20,
        CancellationToken ct = default)
    {
        var sb = new System.Text.StringBuilder($"/api/v0/bounties?limit={limit}");
        if (!string.IsNullOrEmpty(status)) sb.Append($"&status={status}");
        if (!string.IsNullOrEmpty(poster)) sb.Append($"&poster={poster}");
        if (!string.IsNullOrEmpty(submitter)) sb.Append($"&submitter={submitter}");
        var resp = await _transport.GetAsync<BountyListResponse>(sb.ToString(), ct);
        return resp?.Data ?? Array.Empty<Bounty>();
    }

    private sealed class BountyListResponse
    {
        [System.Text.Json.Serialization.JsonPropertyName("data")]
        public Bounty[]? Data { get; set; }
    }

    // ─── Deposit (security collateral) ────────────────────────────────────────

    /// <summary>Locks a security deposit held as collateral for a service agreement.</summary>
    /// <param name="provider">Address of the provider holding the deposit.</param>
    /// <param name="amount">USDC amount to deposit.</param>
    /// <param name="expireSecs">Seconds until deposit expires (default: 86400 = 24h).</param>
    public async Task<Deposit> LockDepositAsync(
        string provider,
        decimal amount,
        int expireSecs = 86400,
        PermitSignature? permit = null,
        CancellationToken ct = default)
    {
        ValidateAddress(provider, nameof(provider));
        ValidateAmount(amount);

        permit ??= await AutoPermitAsync("deposit", amount);

        var expiry = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + expireSecs;
        var body = new Dictionary<string, object?>
        {
            ["chain"]    = _chain,
            ["provider"] = provider,
            ["amount"]   = amount.ToString("F6"),
            ["expiry"]   = expiry,
            ["permit"]   = permit,
        };
        return await _transport.PostAsync<Deposit>("/api/v0/deposits", body, ct);
    }

    /// <summary>Returns a deposit to the depositor (provider-side, no fee).</summary>
    public Task<Transaction> ReturnDepositAsync(string depositId, CancellationToken ct = default) =>
        _transport.PostAsync<Transaction>($"/api/v0/deposits/{depositId}/return", new { }, ct);

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

    // ─── Webhooks ─────────────────────────────────────────────────────────────

    /// <summary>Registers a webhook endpoint to receive event notifications.</summary>
    /// <param name="url">The HTTPS endpoint that will receive POST notifications.</param>
    /// <param name="events">Event types to subscribe to (e.g. "payment.sent", "escrow.funded").</param>
    /// <param name="chains">Optional chain names to filter by (e.g. "base"). Pass null for all chains.</param>
    /// <param name="ct">Cancellation token.</param>
    public Task<Webhook> RegisterWebhookAsync(
        string url,
        IEnumerable<string> events,
        IEnumerable<string>? chains = null,
        CancellationToken ct = default)
        => _transport.PostAsync<Webhook>("/api/v0/webhooks", new
        {
            url,
            events = events.ToList(),
            chains = chains?.ToList(),
        }, ct);

    // ─── One-time operator links ──────────────────────────────────────────────

    /// <summary>Generates a one-time URL for the operator to fund this wallet.</summary>
    /// <param name="messages">Optional chat-style messages shown on the funding page (role: "agent" or "system", text: message).</param>
    /// <param name="agentName">Optional agent display name shown on the funding page.</param>
    public Task<LinkResponse> CreateFundLinkAsync(LinkMessage[]? messages = null, string? agentName = null, CancellationToken ct = default)
    {
        var body = new Dictionary<string, object>();
        if (messages is { Length: > 0 }) body["messages"] = messages;
        if (!string.IsNullOrEmpty(agentName)) body["agent_name"] = agentName!;
        return _transport.PostAsync<LinkResponse>("/api/v0/links/fund", body, ct);
    }

    /// <summary>Generates a one-time URL for the operator to withdraw funds.</summary>
    /// <param name="messages">Optional chat-style messages shown on the withdraw page (role: "agent" or "system", text: message).</param>
    /// <param name="agentName">Optional agent display name shown on the withdraw page.</param>
    public Task<LinkResponse> CreateWithdrawLinkAsync(LinkMessage[]? messages = null, string? agentName = null, CancellationToken ct = default)
    {
        var body = new Dictionary<string, object>();
        if (messages is { Length: > 0 }) body["messages"] = messages;
        if (!string.IsNullOrEmpty(agentName)) body["agent_name"] = agentName!;
        return _transport.PostAsync<LinkResponse>("/api/v0/links/withdraw", body, ct);
    }

    // ─── Contracts ─────────────────────────────────────────────────────────

    /// <summary>Returns contract addresses for the current chain (cached after first call).</summary>
    public async Task<ContractAddresses> GetContractsAsync(CancellationToken ct = default)
    {
        if (_cachedContracts is not null) return _cachedContracts;
        _cachedContracts = await _transport.GetAsync<ContractAddresses>("/api/v0/contracts", ct);
        return _cachedContracts;
    }

    // ─── Mint (testnet only) ──────────────────────────────────────────────

    /// <summary>Mints testnet USDC to this wallet (testnet only).</summary>
    /// <param name="amount">Amount to mint in USDC.</param>
    public Task<MintResponse> MintAsync(decimal amount, CancellationToken ct = default)
    {
        ValidateAmount(amount);
        return _transport.PostAsync<MintResponse>("/api/v0/mint", new
        {
            wallet = Address,
            amount = amount.ToString("F6"),
        }, ct);
    }

    // ─── EIP-2612 Permit ──────────────────────────────────────────────────────

    /// <summary>
    /// Signs an EIP-2612 permit for USDC approval with explicit parameters.
    /// </summary>
    /// <param name="spender">Contract address that will call transferFrom.</param>
    /// <param name="value">Raw USDC amount in base units (6 decimals, e.g. 1_000_000 = $1).</param>
    /// <param name="nonce">Current EIP-2612 nonce for this wallet on the USDC contract.</param>
    /// <param name="deadline">Unix timestamp after which the permit expires.</param>
    /// <param name="usdcAddress">Optional USDC contract address override.</param>
    public PermitSignature SignUsdcPermit(string spender, long value, long nonce, long deadline, string? usdcAddress = null)
    {
        var usdc = usdcAddress ?? (UsdcAddresses.TryGetValue(_chainKey, out var addr) ? addr : "");

        // EIP-712 domain: name="USD Coin", version="2", chainId, verifyingContract=USDC
        var domainTypeHash = Eip712.Keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        var nameHash = Eip712.Keccak256("USD Coin");
        var versionHash = Eip712.Keccak256("2");
        var domainData = ConcatBytes(domainTypeHash, nameHash, versionHash,
            PadUint256Long(_chainId), PadAddressBytes(usdc));
        var domainSep = Eip712.Keccak256(domainData);

        // Permit struct hash
        var typeHash = Eip712.Keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        var structData = ConcatBytes(typeHash,
            PadAddressBytes(Address),
            PadAddressBytes(spender),
            PadUint256Long(value),
            PadUint256Long(nonce),
            PadUint256Long(deadline));
        var structHash = Eip712.Keccak256(structData);

        // Final EIP-712 digest: "\x19\x01" || domainSeparator || structHash
        var payload = new byte[66];
        payload[0] = 0x19;
        payload[1] = 0x01;
        Buffer.BlockCopy(domainSep, 0, payload, 2, 32);
        Buffer.BlockCopy(structHash, 0, payload, 34, 32);
        var digest = Eip712.Keccak256(payload);

        var sig = _signer.Sign(digest);

        // Parse r, s, v from the 65-byte signature
        var sigHex = sig.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? sig[2..] : sig;
        var sigBytes = Convert.FromHexString(sigHex);
        var r = "0x" + Convert.ToHexString(sigBytes, 0, 32).ToLowerInvariant();
        var s = "0x" + Convert.ToHexString(sigBytes, 32, 32).ToLowerInvariant();
        var v = (int)sigBytes[64];

        return new PermitSignature(value, deadline, v, r, s);
    }

    /// <summary>
    /// Signs a USDC permit for <paramref name="spender"/> with automatic nonce fetching.
    /// </summary>
    /// <param name="spender">Contract address that will call transferFrom (e.g. Router, Escrow).</param>
    /// <param name="amount">Amount in USDC (e.g. 1.50 for $1.50).</param>
    /// <param name="deadline">Optional Unix timestamp. Defaults to 1 hour from now.</param>
    public async Task<PermitSignature> SignPermitAsync(string spender, decimal amount, long? deadline = null)
    {
        var usdcAddr = UsdcAddresses.TryGetValue(_chainKey, out var addr) ? addr : "";
        var nonce = await FetchUsdcNonceAsync(usdcAddr);
        var dl = deadline ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600;
        var rawAmount = (long)(amount * 1_000_000m);
        return SignUsdcPermit(spender, rawAmount, nonce, dl, usdcAddr);
    }

    /// <summary>
    /// Auto-signs a permit for the given contract type and amount.
    /// Used internally by payment methods when no explicit permit is provided.
    /// </summary>
    private async Task<PermitSignature> AutoPermitAsync(string contract, decimal amount)
    {
        var contracts = await GetContractsAsync();
        var spender = contract switch
        {
            "router"  => contracts.Router,
            "escrow"  => contracts.Escrow,
            "tab"     => contracts.Tab,
            "stream"  => contracts.Stream,
            "bounty"  => contracts.Bounty,
            "deposit" => contracts.Deposit,
            _ => throw new ArgumentException($"Unknown contract type: {contract}", nameof(contract)),
        };
        if (string.IsNullOrEmpty(spender))
            throw new RemitError(ErrorCodes.ServerError, $"No {contract} contract address available from /contracts endpoint.");
        return await SignPermitAsync(spender, amount);
    }

    /// <summary>Fetches the current EIP-2612 nonce for this wallet from the USDC contract via JSON-RPC.</summary>
    private async Task<long> FetchUsdcNonceAsync(string usdcAddress)
    {
        // Mock mode: no RPC URL means return 0 (used by MockRemit)
        if (string.IsNullOrEmpty(_rpcUrl))
            return 0;

        // nonces(address) selector = 0x7ecebe00 + address padded to 32 bytes
        var paddedAddress = Address.ToLowerInvariant().Replace("0x", "").PadLeft(64, '0');
        var data = $"0x7ecebe00{paddedAddress}";

        var requestBody = new
        {
            jsonrpc = "2.0",
            id = 1,
            method = "eth_call",
            @params = new object[]
            {
                new { to = usdcAddress, data },
                "latest"
            }
        };

        var json = System.Text.Json.JsonSerializer.Serialize(requestBody);
        var content = new StringContent(json, System.Text.Encoding.UTF8, "application/json");
        var response = await RpcClient.PostAsync(_rpcUrl, content);
        var responseBody = await response.Content.ReadAsStringAsync();

        using var doc = System.Text.Json.JsonDocument.Parse(responseBody);
        var result = doc.RootElement.GetProperty("result").GetString()
            ?? throw new RemitError(ErrorCodes.ServerError, "RPC returned null for nonces() call.");

        return Convert.ToInt64(result, 16);
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

    // ─── EIP-712 byte helpers (used by SignTabCharge) ────────────────────────

    private static byte[] PadUint256Long(long value)
    {
        var result = new byte[32];
        var bytes = BitConverter.GetBytes((ulong)value);
        if (BitConverter.IsLittleEndian) Array.Reverse(bytes);
        Buffer.BlockCopy(bytes, 0, result, 24, 8);
        return result;
    }

    private static byte[] PadAddressBytes(string address)
    {
        var hex = address.Replace("0x", "").Replace("0X", "");
        var bytes = Convert.FromHexString(hex);
        var result = new byte[32];
        Buffer.BlockCopy(bytes, 0, result, 12, 20);
        return result;
    }

    private static byte[] ConcatBytes(params byte[][] arrays)
    {
        var total = arrays.Sum(a => a.Length);
        var result = new byte[total];
        var pos = 0;
        foreach (var a in arrays) { Buffer.BlockCopy(a, 0, result, pos, a.Length); pos += a.Length; }
        return result;
    }
}
