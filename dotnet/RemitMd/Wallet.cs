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
    private readonly bool _isMock;
    private ContractAddresses? _cachedContracts;

    // Chain → API base URL map
    private static readonly Dictionary<string, (long ChainId, string ApiUrl)> Chains = new()
    {
        ["base"]               = (8453,  "https://remit.md"),
        ["base-sepolia"]       = (84532, "https://testnet.remit.md"),
    };

    // Chain → USDC contract address
    private static readonly Dictionary<string, string> UsdcAddresses = new()
    {
        ["base-sepolia"] = "0x2d846325766921935f37d5b4478196d3ef93707c",
        ["base"]         = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        ["localhost"]    = "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    };

    // ─── Constructors ─────────────────────────────────────────────────────────

    /// <summary>
    /// Creates a Wallet from a hex-encoded private key.
    /// </summary>
    /// <param name="privateKeyHex">64-character hex private key (0x prefix optional).</param>
    /// <param name="chain">Target chain name: "base". Default: "base".</param>
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
        var key = testnet && !chain.Contains("sepolia") ? $"{chain}-sepolia" : chain;

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
        _chain = key;
        _chainKey = key;
        _isMock = false;
        var envUrl = Environment.GetEnvironmentVariable("REMITMD_API_URL");
        _transport = new HttpTransport(signer, cc.ChainId, routerAddress ?? string.Empty, baseUrl ?? envUrl ?? cc.ApiUrl);
    }

    /// <summary>
    /// Creates a Wallet from the standard environment variables.
    ///
    /// Priority: <c>REMIT_SIGNER_URL</c> + <c>REMIT_SIGNER_TOKEN</c> (HttpSigner) &gt;
    /// <c>REMITMD_KEY</c> (PrivateKeySigner) &gt; error.
    ///
    /// Common env vars: <c>REMITMD_CHAIN</c> (optional), <c>REMITMD_TESTNET</c> (optional),
    /// <c>REMITMD_ROUTER_ADDRESS</c> (optional).
    /// </summary>
    public static Wallet FromEnvironment()
    {
        var chain         = Environment.GetEnvironmentVariable("REMITMD_CHAIN") ?? "base";
        var testnet       = Environment.GetEnvironmentVariable("REMITMD_TESTNET") is "1" or "true";
        var routerAddress = Environment.GetEnvironmentVariable("REMITMD_ROUTER_ADDRESS");

        // Priority 1: HTTP signer server
        var signerUrl = Environment.GetEnvironmentVariable("REMIT_SIGNER_URL");
        if (!string.IsNullOrEmpty(signerUrl))
        {
            var signerToken = Environment.GetEnvironmentVariable("REMIT_SIGNER_TOKEN")
                ?? throw new RemitError(ErrorCodes.Unauthorized,
                    "REMIT_SIGNER_TOKEN is required when REMIT_SIGNER_URL is set.");

            return new Wallet(new HttpSigner(signerUrl, signerToken), chain, testnet, null, routerAddress);
        }

        // Priority 2: Raw private key
        var key = Environment.GetEnvironmentVariable("REMITMD_KEY");
        if (!string.IsNullOrEmpty(key))
            return new Wallet(new PrivateKeySigner(key), chain, testnet, null, routerAddress);

        throw new RemitError(ErrorCodes.InvalidPrivateKey,
            "No signing credentials found. Set one of: " +
            "REMIT_SIGNER_URL + REMIT_SIGNER_TOKEN, or REMITMD_KEY.");
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
        _isMock = true;
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
            ["amount"]    = (object)amount,
            ["task"]      = memo,
            ["chain"]     = _chain,
            ["nonce"]     = nonce,
            ["signature"] = "0x",
            ["permit"]    = permit,
        };
        return await _transport.PostAsync<Transaction>("/api/v1/payments/direct", body, ct);
    }

    // ─── Status & balance ──────────────────────────────────────────────────────

    /// <summary>Returns full wallet status including balance, tier, fee rate, and active primitives.</summary>
    public Task<WalletStatus> StatusAsync(CancellationToken ct = default) =>
        _transport.GetAsync<WalletStatus>($"/api/v1/status/{Address}", ct);

    /// <summary>Returns the current USDC balance for this wallet.</summary>
    public async Task<Balance> BalanceAsync(CancellationToken ct = default)
    {
        var status = await StatusAsync(ct);
        return new Balance(
            decimal.Parse(status.Balance),
            status.Wallet,
            (ChainId)_chainId,
            DateTimeOffset.UtcNow);
    }

    /// <summary>Returns the payment history for this wallet (newest first).</summary>
    /// <param name="page">Page number (1-based).</param>
    /// <param name="perPage">Results per page (max 100).</param>
    public Task<TransactionList> HistoryAsync(int page = 1, int perPage = 20, CancellationToken ct = default) =>
        _transport.GetAsync<TransactionList>($"/api/v1/invoices?page={page}&per_page={perPage}", ct);

    /// <summary>Returns the reputation score for any Ethereum address.</summary>
    /// <param name="address">Address to look up (defaults to this wallet's address).</param>
    public Task<Reputation> ReputationAsync(string? address = null, CancellationToken ct = default) =>
        _transport.GetAsync<Reputation>($"/api/v1/reputation/{address ?? Address}", ct);

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
            ["amount"]     = (object)amount,
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
        await _transport.PostAsync<object>("/api/v1/invoices", invoiceBody, ct);

        // Step 2: fund the escrow.
        permit ??= await AutoPermitAsync("escrow", amount);
        var escrowBody = new Dictionary<string, object?>
        {
            ["invoice_id"] = invoiceId,
            ["permit"]     = permit,
        };
        return await _transport.PostAsync<Escrow>("/api/v1/escrows", escrowBody, ct);
    }

    /// <summary>Releases escrow funds to the payee after work is approved.</summary>
    public Task<Transaction> ReleaseEscrowAsync(string escrowId, CancellationToken ct = default) =>
        _transport.PostAsync<Transaction>($"/api/v1/escrows/{escrowId}/release", new { }, ct);

    /// <summary>Cancels an unfunded escrow and returns funds to the payer.</summary>
    public Task<Transaction> CancelEscrowAsync(string escrowId, CancellationToken ct = default) =>
        _transport.PostAsync<Transaction>($"/api/v1/escrows/{escrowId}/cancel", new { }, ct);

    /// <summary>Signals the provider has started work on an escrow.</summary>
    public Task<Escrow> ClaimStartAsync(string escrowId, CancellationToken ct = default) =>
        _transport.PostAsync<Escrow>($"/api/v1/escrows/{escrowId}/claim-start", new { }, ct);

    /// <summary>Retrieves the current state of an escrow.</summary>
    public Task<Escrow> GetEscrowAsync(string escrowId, CancellationToken ct = default) =>
        _transport.GetAsync<Escrow>($"/api/v1/escrows/{escrowId}", ct);

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
            ["limit_amount"] = (object)limitAmount,
            ["per_unit"]     = (object)perUnit,
            ["expiry"]       = expiry,
            ["permit"]       = permit,
        };
        return await _transport.PostAsync<Tab>("/api/v1/tabs", body, ct);
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
        return _transport.PostAsync<TabCharge>($"/api/v1/tabs/{tabId}/charge", new Dictionary<string, object?>
        {
            ["amount"]       = (object)amount,
            ["cumulative"]   = (object)cumulative,
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
        _transport.PostAsync<Tab>($"/api/v1/tabs/{tabId}/close", new Dictionary<string, object?>
        {
            ["final_amount"] = (object)finalAmount,
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
            ["rate_per_second"] = (object)ratePerSecond,
            ["max_total"]       = (object)maxTotal,
            ["permit"]          = permit,
        };
        return await _transport.PostAsync<Stream>("/api/v1/streams", body, ct);
    }

    /// <summary>Closes a stream, stopping further payments and settling on-chain.</summary>
    public Task<Transaction> CloseStreamAsync(string streamId, CancellationToken ct = default) =>
        _transport.PostAsync<Transaction>($"/api/v1/streams/{streamId}/close", new { }, ct);

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
            ["amount"]           = (object)amount,
            ["task_description"] = taskDescription,
            ["deadline"]         = deadline,
            ["max_attempts"]     = maxAttempts,
            ["permit"]           = permit,
        };
        return await _transport.PostAsync<Bounty>("/api/v1/bounties", body, ct);
    }

    /// <summary>Submits evidence for a bounty.</summary>
    /// <param name="bountyId">Bounty identifier.</param>
    /// <param name="evidenceHash">Hash of the evidence being submitted.</param>
    /// <returns>A BountySubmission with the submission ID.</returns>
    public Task<BountySubmission> SubmitBountyAsync(
        string bountyId,
        string evidenceHash,
        CancellationToken ct = default) =>
        _transport.PostAsync<BountySubmission>($"/api/v1/bounties/{bountyId}/submit",
            new Dictionary<string, object?> { ["evidence_hash"] = evidenceHash }, ct);

    /// <summary>Awards a bounty to a specific submission (poster-only).</summary>
    /// <param name="bountyId">Bounty identifier.</param>
    /// <param name="submissionId">Integer ID of the winning submission.</param>
    public Task<Bounty> AwardBountyAsync(string bountyId, int submissionId, CancellationToken ct = default) =>
        _transport.PostAsync<Bounty>($"/api/v1/bounties/{bountyId}/award",
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
        var sb = new System.Text.StringBuilder($"/api/v1/bounties?limit={limit}");
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
            ["amount"]   = (object)amount,
            ["expiry"]   = expiry,
            ["permit"]   = permit,
        };
        return await _transport.PostAsync<Deposit>("/api/v1/deposits", body, ct);
    }

    /// <summary>Returns a deposit to the depositor (provider-side, no fee).</summary>
    public Task<Transaction> ReturnDepositAsync(string depositId, CancellationToken ct = default) =>
        _transport.PostAsync<Transaction>($"/api/v1/deposits/{depositId}/return", new { }, ct);

    // ─── Analytics & budget ───────────────────────────────────────────────────

    /// <summary>Returns spending analytics for the given period.</summary>
    /// <param name="period">"day", "week", or "month".</param>
    public Task<SpendingSummary> SpendingSummaryAsync(string period = "day", CancellationToken ct = default) =>
        _transport.GetAsync<SpendingSummary>($"/api/v1/invoices?period={period}", ct);

    /// <summary>Returns remaining spending capacity under operator-set budget limits.</summary>
    public Task<Budget> RemainingBudgetAsync(CancellationToken ct = default) =>
        _transport.GetAsync<Budget>($"/api/v1/status/{Address}", ct);

    /// <summary>Proposes a payment intent for negotiation with a counterpart.</summary>
    public Task<Intent> ProposeIntentAsync(
        string to,
        decimal amount,
        string type = "direct",
        CancellationToken ct = default)
    {
        ValidateAddress(to, nameof(to));
        ValidateAmount(amount);
        return _transport.PostAsync<Intent>("/api/v1/invoices", new
        {
            to,
            amount = (object)amount,
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
        => _transport.PostAsync<Webhook>("/api/v1/webhooks", new
        {
            url,
            events = events.ToList(),
            chains = (chains ?? new[] { _chain }).ToList(),
        }, ct);

    // ─── One-time operator links ──────────────────────────────────────────────

    /// <summary>Generates a one-time URL for the operator to fund this wallet.
    /// Auto-signs a permit so the operator can also withdraw from the same link.</summary>
    /// <param name="messages">Optional chat-style messages shown on the funding page (role: "agent" or "system", text: message).</param>
    /// <param name="agentName">Optional agent display name shown on the funding page.</param>
    /// <param name="permit">Optional pre-signed permit. Auto-signed if omitted.</param>
    public async Task<LinkResponse> CreateFundLinkAsync(LinkMessage[]? messages = null, string? agentName = null, PermitSignature? permit = null, CancellationToken ct = default)
    {
        permit ??= await AutoPermitAsync("relayer", 999_999_999m);
        var body = new Dictionary<string, object>();
        if (messages is { Length: > 0 }) body["messages"] = messages;
        if (!string.IsNullOrEmpty(agentName)) body["agent_name"] = agentName!;
        if (permit is not null) body["permit"] = permit;
        return await _transport.PostAsync<LinkResponse>("/api/v1/links/fund", body, ct);
    }

    /// <summary>Generates a one-time URL for the operator to withdraw funds.
    /// Auto-signs a permit (999M USDC to relayer) so the operator can withdraw.</summary>
    /// <param name="messages">Optional chat-style messages shown on the withdraw page (role: "agent" or "system", text: message).</param>
    /// <param name="agentName">Optional agent display name shown on the withdraw page.</param>
    /// <param name="permit">Optional pre-signed permit. Auto-signed if omitted.</param>
    public async Task<LinkResponse> CreateWithdrawLinkAsync(LinkMessage[]? messages = null, string? agentName = null, PermitSignature? permit = null, CancellationToken ct = default)
    {
        permit ??= await AutoPermitAsync("relayer", 999_999_999m);
        var body = new Dictionary<string, object>();
        if (messages is { Length: > 0 }) body["messages"] = messages;
        if (!string.IsNullOrEmpty(agentName)) body["agent_name"] = agentName!;
        if (permit is not null) body["permit"] = permit;
        return await _transport.PostAsync<LinkResponse>("/api/v1/links/withdraw", body, ct);
    }

    // ─── Contracts ─────────────────────────────────────────────────────────

    /// <summary>Returns contract addresses for the current chain (cached after first call).</summary>
    public async Task<ContractAddresses> GetContractsAsync(CancellationToken ct = default)
    {
        if (_cachedContracts is not null) return _cachedContracts;
        _cachedContracts = await _transport.GetAsync<ContractAddresses>("/api/v1/contracts", ct);
        return _cachedContracts;
    }

    // ─── Mint (testnet only) ──────────────────────────────────────────────

    /// <summary>Mints testnet USDC to this wallet (testnet only).</summary>
    /// <param name="amount">Amount to mint in USDC.</param>
    public Task<MintResponse> MintAsync(decimal amount, CancellationToken ct = default)
    {
        ValidateAmount(amount);
        return _transport.PostAsync<MintResponse>("/api/v1/mint", new
        {
            wallet = Address,
            amount = (object)amount,
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
        var usdc = usdcAddress ?? (UsdcAddresses.TryGetValue(_chainKey, out var addr) ? addr : null)
            ?? throw new RemitError(ErrorCodes.InvalidChain,
                $"No USDC address for chain '{_chainKey}'. Supported: {string.Join(", ", UsdcAddresses.Keys)}. Pass usdcAddress explicitly.");

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
        var usdcAddr = UsdcAddresses.TryGetValue(_chainKey, out var a) ? a : null;
        if (string.IsNullOrEmpty(usdcAddr))
            throw new RemitError(ErrorCodes.InvalidChain,
                $"No USDC address for chain '{_chainKey}'. Supported: {string.Join(", ", UsdcAddresses.Keys)}. Use SignUsdcPermit() with explicit address.");
        var nonce = await FetchPermitNonceAsync(usdcAddr);
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
            "relayer" => contracts.Relayer,
            _ => throw new ArgumentException($"Unknown contract type: {contract}", nameof(contract)),
        };
        if (string.IsNullOrEmpty(spender))
            throw new RemitError(ErrorCodes.ServerError, $"No {contract} contract address available from /contracts endpoint.");
        return await SignPermitAsync(spender, amount);
    }

    /// <summary>
    /// Fetches the EIP-2612 permit nonce from the API.
    /// </summary>
    private async Task<long> FetchPermitNonceAsync(string usdcAddress)
    {
        // Mock mode: return 0 directly (used by MockRemit)
        if (_isMock)
            return 0;

        var status = await _transport.GetAsync<System.Text.Json.JsonElement>(
            $"/api/v1/status/{Address}", CancellationToken.None);
        if (status.TryGetProperty("permit_nonce", out var nonceElem))
        {
            if (nonceElem.ValueKind == System.Text.Json.JsonValueKind.Number)
                return nonceElem.GetInt64();
            if (nonceElem.ValueKind == System.Text.Json.JsonValueKind.String)
            {
                var s = nonceElem.GetString();
                if (s is not null && long.TryParse(s, out var parsed))
                    return parsed;
            }
        }
        throw new RemitError(ErrorCodes.ServerError,
            $"permit_nonce not available from /status API for {Address}");
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
