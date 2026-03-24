package md.remit;

import md.remit.internal.ApiClient;
import md.remit.models.*;
import md.remit.signer.Signer;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.OptionalLong;

/**
 * Primary remit.md client for agents that send and receive payments.
 *
 * <p><b>Quick start (1 line):</b>
 * <pre>{@code
 * Wallet wallet = RemitMd.fromEnv();
 * wallet.pay("0xRecipient...", new BigDecimal("1.50"));
 * }</pre>
 *
 * <p>All methods throw {@link RemitError} with actionable messages on failure.
 * Use {@link MockRemit} for unit tests — zero network, zero latency.
 */
public class Wallet {

    private static final Map<String, String> USDC_ADDRESSES = Map.of(
        "base-sepolia", "0x2d846325766921935f37d5b4478196d3ef93707c",
        "base", "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        "localhost", "0x5FbDB2315678afecb367f032d93F642f64180aa3"
    );

    private static final Map<String, String> DEFAULT_RPC_URLS = Map.of(
        "base-sepolia", "https://sepolia.base.org",
        "base", "https://mainnet.base.org",
        "localhost", "http://127.0.0.1:8545"
    );

    private final ApiClient client;
    private final Signer signer;
    private final long chainId;
    private final String chain;
    private final String rpcUrl;
    private volatile ContractAddresses contractsCache;

    Wallet(ApiClient client, Signer signer, long chainId, String chain, String rpcUrl) {
        this.client = client;
        this.signer = signer;
        this.chainId = chainId;
        this.chain = chain;
        this.rpcUrl = rpcUrl;
    }

    /** The Ethereum address (0x-prefixed) of this wallet. */
    public String address() {
        return signer.address();
    }

    /** Package-private accessor for the signer (used by X402Client). */
    Signer signer() {
        return signer;
    }

    /** The chain ID this wallet is connected to. */
    public long chainId() {
        return chainId;
    }

    // ─── Balance ──────────────────────────────────────────────────────────────

    /** Returns the current USDC balance of this wallet. */
    public Balance balance() {
        return client.get("/api/v1/wallet/balance", Balance.class);
    }

    // ─── Direct Payment ───────────────────────────────────────────────────────

    /**
     * Sends a direct USDC payment. No escrow — one-way transfer.
     *
     * @param to     recipient Ethereum address (0x-prefixed, 42 chars)
     * @param amount USDC amount, minimum 0.000001
     * @throws RemitError INVALID_ADDRESS if {@code to} is malformed
     * @throws RemitError INVALID_AMOUNT if {@code amount} is below minimum or above 1,000,000
     * @throws RemitError INSUFFICIENT_FUNDS if wallet balance is too low
     */
    public Transaction pay(String to, BigDecimal amount) {
        return pay(to, amount, (String) null, null);
    }

    /** Sends a direct USDC payment with a memo string. */
    public Transaction pay(String to, BigDecimal amount, String memo) {
        return pay(to, amount, memo, null);
    }

    /** Sends a direct USDC payment with a permit for gasless approval. */
    public Transaction pay(String to, BigDecimal amount, PermitSignature permit) {
        return pay(to, amount, (String) null, permit);
    }

    /** Sends a direct USDC payment with an optional memo and permit. */
    public Transaction pay(String to, BigDecimal amount, String memo, PermitSignature permit) {
        validateAddress(to);
        validateAmount(amount);
        PermitSignature p = permit != null ? permit : autoPermit("router", amount);
        byte[] nb = new byte[16];
        new java.security.SecureRandom().nextBytes(nb);
        String nonce = java.util.HexFormat.of().formatHex(nb);
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("to", to);
        body.put("amount", amount.toPlainString());
        body.put("task", memo != null ? memo : "");
        body.put("chain", chain);
        body.put("nonce", nonce);
        body.put("signature", "0x");
        if (p != null) body.put("permit", p);
        return client.post("/api/v1/payments/direct", body, Transaction.class);
    }

    // ─── Transaction History ──────────────────────────────────────────────────

    /**
     * Returns paginated transaction history.
     *
     * @param page    1-based page number (default 1)
     * @param perPage items per page (default 50, max 200)
     */
    public TransactionList history(int page, int perPage) {
        return client.get("/api/v1/wallet/history?page=" + page + "&per_page=" + perPage, TransactionList.class);
    }

    /** Returns the first page of transaction history (50 items). */
    public TransactionList history() {
        return client.get("/api/v1/wallet/history", TransactionList.class);
    }

    // ─── Reputation ───────────────────────────────────────────────────────────

    /** Returns the on-chain reputation for a given address. */
    public Reputation reputation(String address) {
        validateAddress(address);
        return client.get("/api/v1/reputation/" + address, Reputation.class);
    }

    // ─── Escrow ───────────────────────────────────────────────────────────────

    /**
     * Creates and funds an escrow. Funds are locked until {@link #releaseEscrow} or expiry.
     *
     * @param payee  recipient address
     * @param amount USDC to lock in escrow
     */
    public Escrow createEscrow(String payee, BigDecimal amount) {
        return createEscrow(payee, amount, null, null, null, null, null);
    }

    /** Creates an escrow with a permit for gasless approval. */
    public Escrow createEscrow(String payee, BigDecimal amount, PermitSignature permit) {
        return createEscrow(payee, amount, null, null, null, null, permit);
    }

    /** Creates an escrow with an optional memo and expiry. */
    public Escrow createEscrow(String payee, BigDecimal amount, String memo, Duration expiresIn) {
        return createEscrow(payee, amount, memo, expiresIn, null, null, null);
    }

    /** Creates an escrow with milestone-based partial payments. */
    public Escrow createEscrow(String payee, BigDecimal amount, String memo, Duration expiresIn,
                                List<Escrow.Milestone> milestones, List<Escrow.Split> splits) {
        return createEscrow(payee, amount, memo, expiresIn, milestones, splits, null);
    }

    /** Creates an escrow with milestone-based partial payments and optional permit. */
    public Escrow createEscrow(String payee, BigDecimal amount, String memo, Duration expiresIn,
                                List<Escrow.Milestone> milestones, List<Escrow.Split> splits,
                                PermitSignature permit) {
        validateAddress(payee);
        validateAmount(amount);
        PermitSignature p = permit != null ? permit : autoPermit("escrow", amount);

        // Step 1: create invoice on server.
        byte[] nb = new byte[16];
        new java.security.SecureRandom().nextBytes(nb);
        String invoiceId = java.util.HexFormat.of().formatHex(nb);
        String nonce = java.util.HexFormat.of().formatHex(nb);

        Map<String, Object> invoiceBody = new java.util.HashMap<>();
        invoiceBody.put("id", invoiceId);
        invoiceBody.put("chain", chain);
        invoiceBody.put("from_agent", signer.address().toLowerCase());
        invoiceBody.put("to_agent", payee.toLowerCase());
        invoiceBody.put("amount", amount.toPlainString());
        invoiceBody.put("type", "escrow");
        invoiceBody.put("task", memo != null ? memo : "");
        invoiceBody.put("nonce", nonce);
        invoiceBody.put("signature", "0x");
        if (expiresIn != null) invoiceBody.put("escrow_timeout", (int) expiresIn.toSeconds());

        client.post("/api/v1/invoices", invoiceBody, Map.class);

        // Step 2: fund the escrow.
        Map<String, Object> escrowBody = new java.util.HashMap<>();
        escrowBody.put("invoice_id", invoiceId);
        if (p != null) escrowBody.put("permit", p);

        return client.post("/api/v1/escrows", escrowBody, Escrow.class);
    }

    /** Releases escrow funds to the payee. */
    public Transaction releaseEscrow(String escrowId) {
        return client.post("/api/v1/escrows/" + escrowId + "/release",
            Map.of("escrow_id", escrowId), Transaction.class);
    }

    /** Releases a specific milestone within an escrow. */
    public Transaction releaseEscrowMilestone(String escrowId, String milestoneId) {
        return client.post("/api/v1/escrows/" + escrowId + "/release",
            Map.of("escrow_id", escrowId, "milestone_id", milestoneId), Transaction.class);
    }

    /** Cancels an escrow and returns funds to the payer. */
    public Transaction cancelEscrow(String escrowId) {
        return client.post("/api/v1/escrows/" + escrowId + "/cancel", null, Transaction.class);
    }

    /** Returns the current state of an escrow. */
    public Escrow getEscrow(String escrowId) {
        return client.get("/api/v1/escrows/" + escrowId, Escrow.class);
    }

    /** Signals the provider has started work on an escrow. */
    public Escrow claimStart(String escrowId) {
        return client.post("/api/v1/escrows/" + escrowId + "/claim-start", Map.of(), Escrow.class);
    }

    // ─── Tab ──────────────────────────────────────────────────────────────────

    /**
     * Opens a payment channel for batched micro-payments.
     *
     * @param provider   the provider's address
     * @param limitAmount maximum USDC that can be charged through this tab
     * @param perUnit    price per unit of work
     */
    public Tab createTab(String provider, BigDecimal limitAmount, BigDecimal perUnit) {
        return createTab(provider, limitAmount, perUnit, 86400, null);
    }

    /** Opens a tab with a permit for gasless approval. */
    public Tab createTab(String provider, BigDecimal limitAmount, BigDecimal perUnit, PermitSignature permit) {
        return createTab(provider, limitAmount, perUnit, 86400, permit);
    }

    /** Opens a tab with an explicit expiry (in seconds from now). */
    public Tab createTab(String provider, BigDecimal limitAmount, BigDecimal perUnit, int expiresInSeconds) {
        return createTab(provider, limitAmount, perUnit, expiresInSeconds, null);
    }

    /** Opens a tab with an optional expiry and permit. */
    public Tab createTab(String provider, BigDecimal limitAmount, BigDecimal perUnit, int expiresInSeconds, PermitSignature permit) {
        validateAddress(provider);
        PermitSignature p = permit != null ? permit : autoPermit("tab", limitAmount);
        long expiry = Instant.now().getEpochSecond() + expiresInSeconds;
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("chain", chain);
        body.put("provider", provider);
        body.put("limit_amount", limitAmount.toPlainString());
        body.put("per_unit", perUnit.toPlainString());
        body.put("expiry", expiry);
        if (p != null) body.put("permit", p);
        return client.post("/api/v1/tabs", body, Tab.class);
    }

    /**
     * Charges a tab with an EIP-712 TabCharge signature (provider-side).
     *
     * @param tabId       tab UUID
     * @param amount      amount to charge for this call
     * @param cumulative  cumulative amount charged so far (including this charge)
     * @param callCount   number of charges made (including this one)
     * @param providerSig EIP-712 TabCharge signature from the provider
     */
    public TabCharge chargeTab(String tabId, BigDecimal amount, BigDecimal cumulative, int callCount, String providerSig) {
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("amount", amount.toPlainString());
        body.put("cumulative", cumulative.toPlainString());
        body.put("call_count", callCount);
        body.put("provider_sig", providerSig);
        return client.post("/api/v1/tabs/" + tabId + "/charge", body, TabCharge.class);
    }

    /**
     * Closes a tab and settles on-chain.
     *
     * @param tabId       tab UUID
     * @param finalAmount final cumulative charged amount
     * @param providerSig EIP-712 TabCharge signature for the final state
     */
    public Tab closeTab(String tabId, BigDecimal finalAmount, String providerSig) {
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("final_amount", finalAmount.toPlainString());
        body.put("provider_sig", providerSig);
        return client.post("/api/v1/tabs/" + tabId + "/close", body, Tab.class);
    }

    /**
     * Signs a TabCharge EIP-712 message (provider-side).
     *
     * @param tabContract    Tab contract address (verifyingContract for domain)
     * @param tabId          UUID of the tab (encoded as bytes32)
     * @param totalCharged   cumulative charged amount in USDC base units (uint96)
     * @param callCount      number of charges made (uint32)
     * @return 0x-prefixed hex signature
     */
    public String signTabCharge(String tabContract, String tabId, long totalCharged, int callCount) {
        // Encode UUID string as bytes32 (ASCII chars padded to 32 bytes).
        byte[] tabIdBytes = new byte[32];
        byte[] ascii = tabId.getBytes(StandardCharsets.US_ASCII);
        System.arraycopy(ascii, 0, tabIdBytes, 0, Math.min(ascii.length, 32));

        // Domain: RemitTab, version 1
        byte[] domainTypeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                .getBytes(StandardCharsets.UTF_8));
        byte[] nameHash = keccak256("RemitTab".getBytes(StandardCharsets.UTF_8));
        byte[] versionHash = keccak256("1".getBytes(StandardCharsets.UTF_8));
        byte[] chainIdBytes = ApiClient.toUint256(chainId);
        byte[] contractBytes = addressToBytes32(tabContract);

        byte[] domainSep = keccak256(concatBytes(domainTypeHash, nameHash, versionHash, chainIdBytes, contractBytes));

        // Struct hash: TabCharge(bytes32 tabId, uint96 totalCharged, uint32 callCount)
        byte[] typeHash = keccak256(
            "TabCharge(bytes32 tabId,uint96 totalCharged,uint32 callCount)"
                .getBytes(StandardCharsets.UTF_8));

        byte[] structHash = keccak256(concatBytes(
            typeHash,
            tabIdBytes,
            ApiClient.toUint256(totalCharged),
            ApiClient.toUint256(callCount)));

        // EIP-712 digest: "\x19\x01" || domainSeparator || structHash
        byte[] finalData = new byte[2 + 32 + 32];
        finalData[0] = 0x19;
        finalData[1] = 0x01;
        System.arraycopy(domainSep, 0, finalData, 2, 32);
        System.arraycopy(structHash, 0, finalData, 34, 32);
        byte[] digest = keccak256(finalData);

        try {
            byte[] sig = signer.sign(digest);
            return "0x" + HexFormat.of().formatHex(sig);
        } catch (Exception e) {
            throw new RemitError(ErrorCodes.INVALID_SIGNATURE,
                "Failed to sign TabCharge. Check that your private key is valid.",
                Map.of());
        }
    }

    // ─── Stream ───────────────────────────────────────────────────────────────

    /**
     * Starts a per-second USDC payment stream.
     *
     * @param payee         receiving address
     * @param ratePerSecond USDC per second (e.g., 0.1)
     * @param maxTotal      maximum total USDC the stream can pay out
     */
    public Stream createStream(String payee, BigDecimal ratePerSecond, BigDecimal maxTotal) {
        return createStream(payee, ratePerSecond, maxTotal, null);
    }

    /** Starts a per-second USDC payment stream with a permit for gasless approval. */
    public Stream createStream(String payee, BigDecimal ratePerSecond, BigDecimal maxTotal, PermitSignature permit) {
        validateAddress(payee);
        PermitSignature p = permit != null ? permit : autoPermit("stream", maxTotal);
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("chain", chain);
        body.put("payee", payee);
        body.put("rate_per_second", ratePerSecond.toPlainString());
        body.put("max_total", maxTotal.toPlainString());
        if (p != null) body.put("permit", p);
        return client.post("/api/v1/streams", body, Stream.class);
    }

    /** Closes a stream and settles on-chain (payer only). */
    public Stream closeStream(String streamId) {
        return client.post("/api/v1/streams/" + streamId + "/close", Map.of(), Stream.class);
    }

    /** Claims all vested stream payments (callable by recipient). */
    public Transaction withdrawStream(String streamId) {
        return client.post("/api/v1/streams/" + streamId + "/withdraw", null, Transaction.class);
    }

    // ─── Bounty ───────────────────────────────────────────────────────────────

    /**
     * Posts a USDC bounty for task completion.
     *
     * @param amount          bounty amount in USDC
     * @param taskDescription human-readable task description
     * @param deadline        deadline as unix timestamp (epoch seconds)
     */
    public Bounty createBounty(BigDecimal amount, String taskDescription, long deadline) {
        return createBounty(amount, taskDescription, deadline, 10, null);
    }

    /** Posts a bounty with a permit for gasless approval. */
    public Bounty createBounty(BigDecimal amount, String taskDescription, long deadline, PermitSignature permit) {
        return createBounty(amount, taskDescription, deadline, 10, permit);
    }

    /** Posts a bounty with max attempts and an optional permit. */
    public Bounty createBounty(BigDecimal amount, String taskDescription, long deadline, int maxAttempts, PermitSignature permit) {
        validateAmount(amount);
        PermitSignature p = permit != null ? permit : autoPermit("bounty", amount);
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("chain", chain);
        body.put("amount", amount.toPlainString());
        body.put("task_description", taskDescription);
        body.put("deadline", deadline);
        body.put("max_attempts", maxAttempts);
        if (p != null) body.put("permit", p);
        return client.post("/api/v1/bounties", body, Bounty.class);
    }

    /**
     * Submits evidence for a bounty.
     *
     * @param bountyId     bounty UUID
     * @param evidenceHash 0x-prefixed hash of the evidence
     * @return submission with its ID (needed for {@link #awardBounty})
     */
    public BountySubmission submitBounty(String bountyId, String evidenceHash) {
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("evidence_hash", evidenceHash);
        return client.post("/api/v1/bounties/" + bountyId + "/submit", body, BountySubmission.class);
    }

    /**
     * Awards a bounty to a specific submission (poster-only).
     *
     * @param bountyId     bounty UUID
     * @param submissionId submission ID returned by {@link #submitBounty}
     */
    public Bounty awardBounty(String bountyId, int submissionId) {
        return client.post("/api/v1/bounties/" + bountyId + "/award",
            Map.of("submission_id", submissionId), Bounty.class);
    }

    /**
     * Lists bounties, optionally filtering by status, poster, or submitter.
     *
     * @param status    filter by status (open, claimed, awarded, expired) — may be null
     * @param poster    filter by poster wallet address — may be null
     * @param submitter filter by submitter wallet address — may be null
     * @param limit     max results (default 20, max 100)
     */
    public java.util.List<Bounty> listBounties(String status, String poster, String submitter, int limit) {
        StringBuilder sb = new StringBuilder("/api/v1/bounties?limit=").append(limit);
        if (status != null && !status.isEmpty()) sb.append("&status=").append(status);
        if (poster != null && !poster.isEmpty()) sb.append("&poster=").append(poster);
        if (submitter != null && !submitter.isEmpty()) sb.append("&submitter=").append(submitter);
        BountyList resp = client.get(sb.toString(), BountyList.class);
        return resp.data != null ? resp.data : java.util.List.of();
    }

    /** Lists open bounties (convenience overload). */
    public java.util.List<Bounty> listBounties() {
        return listBounties("open", null, null, 20);
    }

    // ─── Deposit ──────────────────────────────────────────────────────────────

    /**
     * Locks a security deposit with a provider.
     *
     * @param provider   the provider's address
     * @param amount     USDC to lock
     * @param expiresIn  how long the deposit remains locked (seconds from now)
     */
    public Deposit lockDeposit(String provider, BigDecimal amount, int expiresIn) {
        return lockDeposit(provider, amount, expiresIn, null);
    }

    /** Locks a security deposit with a permit for gasless approval. */
    public Deposit lockDeposit(String provider, BigDecimal amount, int expiresIn, PermitSignature permit) {
        validateAddress(provider);
        validateAmount(amount);
        PermitSignature p = permit != null ? permit : autoPermit("deposit", amount);
        long expiry = Instant.now().getEpochSecond() + expiresIn;
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("chain", chain);
        body.put("provider", provider);
        body.put("amount", amount.toPlainString());
        body.put("expiry", expiry);
        if (p != null) body.put("permit", p);
        return client.post("/api/v1/deposits", body, Deposit.class);
    }

    /** Returns a deposit (provider-side, full refund to depositor). */
    public Deposit returnDeposit(String depositId) {
        return client.post("/api/v1/deposits/" + depositId + "/return", Map.of(), Deposit.class);
    }

    // ─── Analytics ────────────────────────────────────────────────────────────

    /**
     * Returns spending analytics.
     *
     * @param period "day", "week", "month", or "all"
     */
    public SpendingSummary spendingSummary(String period) {
        return client.get("/api/v1/wallet/spending?period=" + period, SpendingSummary.class);
    }

    /** Returns how much the agent can still spend under operator-set limits. */
    public Budget remainingBudget() {
        return client.get("/api/v1/wallet/budget", Budget.class);
    }

    // ─── Contracts ─────────────────────────────────────────────────────────────

    /**
     * Returns the on-chain contract addresses for the current deployment.
     * Results are cached after the first call.
     */
    public ContractAddresses getContracts() {
        ContractAddresses cached = contractsCache;
        if (cached != null) return cached;
        synchronized (this) {
            if (contractsCache != null) return contractsCache;
            contractsCache = client.get("/api/v1/contracts", ContractAddresses.class);
            return contractsCache;
        }
    }

    // ─── Mint (testnet only) ─────────────────────────────────────────────────

    /**
     * Mints testnet USDC to this wallet.
     * Only available on testnet deployments.
     *
     * @param amount USDC amount to mint
     */
    public MintResponse mint(double amount) {
        return client.post("/api/v1/mint",
            Map.of("wallet", address(), "amount", amount),
            MintResponse.class);
    }

    // ─── Validation ───────────────────────────────────────────────────────────

    static void validateAddress(String addr) {
        if (addr == null || !addr.matches("0x[0-9a-fA-F]{40}")) {
            throw new RemitError(
                ErrorCodes.INVALID_ADDRESS,
                "Invalid address \"" + addr + "\": expected 0x-prefixed 40-character hex string (Ethereum address). " +
                "See remit.md/docs/addresses",
                Map.of("address", addr != null ? addr : "null")
            );
        }
    }

    // ─── Webhooks ─────────────────────────────────────────────────────────────

    /**
     * Registers a webhook endpoint to receive event notifications.
     *
     * @param url    the HTTPS endpoint that will receive POST notifications
     * @param events event types to subscribe to (e.g. "payment.sent", "escrow.funded")
     * @param chains optional chain names to filter by — pass null for all chains
     */
    public Webhook registerWebhook(String url, List<String> events, List<String> chains) {
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("url", url);
        body.put("events", events);
        if (chains != null) body.put("chains", chains);
        return client.post("/api/v1/webhooks", body, Webhook.class);
    }

    /** Registers a webhook for all chains. */
    public Webhook registerWebhook(String url, List<String> events) {
        return registerWebhook(url, events, null);
    }

    // ─── One-time operator links ──────────────────────────────────────────────

    /**
     * Generates a one-time URL for the operator to fund this wallet.
     * Auto-signs a permit so the operator can also withdraw from the same link.
     */
    public LinkResponse createFundLink() {
        return createFundLink(null, null, null);
    }

    /**
     * Generates a one-time URL for the operator to fund this wallet.
     * Auto-signs a permit so the operator can also withdraw from the same link.
     *
     * @param messages  optional chat-style messages shown on the funding page (each map has "role" and "text")
     * @param agentName optional agent display name shown on the funding page
     */
    public LinkResponse createFundLink(List<Map<String, String>> messages, String agentName) {
        return createFundLink(messages, agentName, null);
    }

    /**
     * Generates a one-time URL for the operator to fund this wallet with an explicit permit.
     *
     * @param messages  optional chat-style messages shown on the funding page (each map has "role" and "text")
     * @param agentName optional agent display name shown on the funding page
     * @param permit    optional pre-signed permit; auto-signs for the relayer if null
     */
    public LinkResponse createFundLink(List<Map<String, String>> messages, String agentName, PermitSignature permit) {
        PermitSignature p = permit != null ? permit : autoPermit("relayer", new BigDecimal("999999999"));
        Map<String, Object> body = new java.util.HashMap<>();
        if (messages != null && !messages.isEmpty()) body.put("messages", messages);
        if (agentName != null && !agentName.isEmpty()) body.put("agent_name", agentName);
        if (p != null) body.put("permit", p);
        return client.post("/api/v1/links/fund", body, LinkResponse.class);
    }

    /**
     * Generates a one-time URL for the operator to withdraw funds.
     * Auto-signs a permit for the relayer to enable non-custodial withdrawals.
     */
    public LinkResponse createWithdrawLink() {
        return createWithdrawLink(null, null, null);
    }

    /**
     * Generates a one-time URL for the operator to withdraw funds.
     * Auto-signs a permit for the relayer to enable non-custodial withdrawals.
     *
     * @param messages  optional chat-style messages shown on the withdraw page (each map has "role" and "text")
     * @param agentName optional agent display name shown on the withdraw page
     */
    public LinkResponse createWithdrawLink(List<Map<String, String>> messages, String agentName) {
        return createWithdrawLink(messages, agentName, null);
    }

    /**
     * Generates a one-time URL for the operator to withdraw funds with an explicit permit.
     *
     * @param messages  optional chat-style messages shown on the withdraw page (each map has "role" and "text")
     * @param agentName optional agent display name shown on the withdraw page
     * @param permit    optional pre-signed permit; auto-signs for the relayer if null
     */
    public LinkResponse createWithdrawLink(List<Map<String, String>> messages, String agentName, PermitSignature permit) {
        PermitSignature p = permit != null ? permit : autoPermit("relayer", new BigDecimal("999999999"));
        Map<String, Object> body = new java.util.HashMap<>();
        if (messages != null && !messages.isEmpty()) body.put("messages", messages);
        if (agentName != null && !agentName.isEmpty()) body.put("agent_name", agentName);
        if (p != null) body.put("permit", p);
        return client.post("/api/v1/links/withdraw", body, LinkResponse.class);
    }

    // ─── Permit Signing ────────────────────────────────────────────────────

    /**
     * Signs an EIP-2612 permit for USDC approval (low-level).
     *
     * <p>Domain: name="USD Coin", version="2", chainId, verifyingContract=USDC address.
     * Type: Permit(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline).
     *
     * @param spender   contract address that will call transferFrom
     * @param value     amount in USDC base units (6 decimals, e.g. 1_000_000 = $1.00)
     * @param deadline  Unix timestamp after which the permit is invalid
     * @param nonce     the owner's current EIP-2612 nonce on the USDC contract
     * @return PermitSignature with v, r, s, value, deadline
     */
    public PermitSignature signUsdcPermit(String spender, long value, long deadline, long nonce) {
        return signUsdcPermit(spender, value, deadline, nonce, null);
    }

    /**
     * Signs an EIP-2612 permit for USDC approval (low-level, custom USDC address).
     *
     * @param spender       contract address that will call transferFrom
     * @param value         amount in USDC base units (6 decimals)
     * @param deadline      Unix timestamp after which the permit is invalid
     * @param nonce         the owner's current EIP-2612 nonce on the USDC contract
     * @param usdcAddress   override USDC contract address (null = chain default)
     * @return PermitSignature with v, r, s, value, deadline
     */
    public PermitSignature signUsdcPermit(String spender, long value, long deadline, long nonce, String usdcAddress) {
        String usdc = usdcAddress != null ? usdcAddress : USDC_ADDRESSES.getOrDefault(chain, "");
        if (usdc.isEmpty()) {
            throw new RemitError(ErrorCodes.INVALID_CHAIN,
                "No USDC address known for chain \"" + chain + "\". Pass usdcAddress explicitly.",
                Map.of("chain", chain));
        }

        // Domain: name="USD Coin", version="2"
        byte[] domainTypeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                .getBytes(StandardCharsets.UTF_8));
        byte[] nameHash = keccak256("USD Coin".getBytes(StandardCharsets.UTF_8));
        byte[] versionHash = keccak256("2".getBytes(StandardCharsets.UTF_8));
        byte[] chainIdBytes = ApiClient.toUint256(chainId);
        byte[] contractBytes = addressToBytes32(usdc);

        byte[] domainSep = keccak256(concatBytes(domainTypeHash, nameHash, versionHash, chainIdBytes, contractBytes));

        // Struct hash: Permit(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        byte[] typeHash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                .getBytes(StandardCharsets.UTF_8));

        byte[] structHash = keccak256(concatBytes(
            typeHash,
            addressToBytes32(signer.address()),
            addressToBytes32(spender),
            ApiClient.toUint256(value),
            ApiClient.toUint256(nonce),
            ApiClient.toUint256(deadline)));

        // EIP-712 digest: "\x19\x01" || domainSeparator || structHash
        byte[] finalData = new byte[2 + 32 + 32];
        finalData[0] = 0x19;
        finalData[1] = 0x01;
        System.arraycopy(domainSep, 0, finalData, 2, 32);
        System.arraycopy(structHash, 0, finalData, 34, 32);
        byte[] digest = keccak256(finalData);

        try {
            byte[] sig = signer.sign(digest);
            String r = "0x" + HexFormat.of().formatHex(sig, 0, 32);
            String s = "0x" + HexFormat.of().formatHex(sig, 32, 64);
            int v = sig[64] & 0xFF;
            return new PermitSignature(value, deadline, v, r, s);
        } catch (Exception e) {
            throw new RemitError(ErrorCodes.INVALID_SIGNATURE,
                "Failed to sign USDC permit. Check that your private key is valid.",
                Map.of());
        }
    }

    /**
     * Convenience: sign an EIP-2612 permit for USDC approval.
     * Auto-fetches the on-chain nonce and sets a default deadline (1 hour from now).
     *
     * @param spender  contract address that will call transferFrom (e.g. Router, Escrow)
     * @param amount   amount in USDC (e.g. 1.50 for $1.50)
     * @return PermitSignature ready to pass to any payment method
     */
    public PermitSignature signPermit(String spender, BigDecimal amount) {
        return signPermit(spender, amount, OptionalLong.empty());
    }

    /**
     * Convenience: sign an EIP-2612 permit for USDC approval with optional deadline.
     *
     * @param spender  contract address that will call transferFrom
     * @param amount   amount in USDC (e.g. 1.50 for $1.50)
     * @param deadline optional Unix timestamp; defaults to 1 hour from now if empty
     * @return PermitSignature ready to pass to any payment method
     */
    public PermitSignature signPermit(String spender, BigDecimal amount, OptionalLong deadline) {
        String usdc = USDC_ADDRESSES.getOrDefault(chain, "");
        if (usdc.isEmpty()) {
            throw new RemitError(ErrorCodes.INVALID_CHAIN,
                "No USDC address known for chain \"" + chain + "\". Cannot auto-sign permit.",
                Map.of("chain", chain));
        }
        long nonce = fetchPermitNonce(usdc);
        long dl = deadline.orElse(Instant.now().getEpochSecond() + 3600);
        long rawAmount = amount.movePointRight(6).longValueExact();
        return signUsdcPermit(spender, rawAmount, dl, nonce);
    }

    /**
     * Auto-signs a permit for the given contract type and amount.
     * Used internally by payment methods when no explicit permit is provided.
     * Returns null if permit signing is unavailable (e.g. mock context, no RPC).
     */
    private PermitSignature autoPermit(String contractField, BigDecimal amount) {
        try {
            ContractAddresses contracts = getContracts();
            String spender;
            switch (contractField) {
                case "router":  spender = contracts.router;  break;
                case "escrow":  spender = contracts.escrow;  break;
                case "tab":     spender = contracts.tab;     break;
                case "stream":  spender = contracts.stream;  break;
                case "bounty":  spender = contracts.bounty;  break;
                case "deposit": spender = contracts.deposit;  break;
                case "relayer": spender = contracts.relayer;  break;
                default:        return null;
            }
            if (spender == null || spender.isBlank()) return null;
            return signPermit(spender, amount);
        } catch (Exception e) {
            // Permit signing unavailable (no RPC, mock context, etc.)
            // Fall through — server will handle approval via other means
            System.err.println("[remitmd] auto-permit failed for " + contractField + ": " + e.getMessage());
            return null;
        }
    }

    /**
     * Fetches the EIP-2612 permit nonce, trying the API first then falling back to RPC.
     */
    @SuppressWarnings("unchecked")
    private long fetchPermitNonce(String usdcAddress) {
        // Try the status API first — it's cheaper than a direct RPC call.
        try {
            Map<String, Object> data = client.get(
                "/api/v1/status/" + signer.address(), Map.class);
            Object nonce = data != null ? data.get("permit_nonce") : null;
            if (nonce != null) {
                return ((Number) nonce).longValue();
            }
        } catch (Exception e) {
            System.err.println("[remitmd] permit nonce API lookup failed, falling back to RPC: " + e.getMessage());
        }

        // Fall back to direct RPC call.
        return fetchUsdcNonceRpc(usdcAddress);
    }

    /**
     * Fetches the current EIP-2612 nonce for this wallet from the USDC contract via JSON-RPC.
     */
    private long fetchUsdcNonceRpc(String usdcAddress) {
        // nonces(address) selector = 0x7ecebe00 + address padded to 32 bytes
        String addr = signer.address().toLowerCase().replace("0x", "");
        String paddedAddress = String.format("%64s", addr).replace(' ', '0');
        String data = "0x7ecebe00" + paddedAddress;

        String rpc = this.rpcUrl;
        if (rpc == null || rpc.isBlank()) {
            rpc = DEFAULT_RPC_URLS.getOrDefault(chain, "");
        }
        if (rpc.isEmpty()) {
            throw new RemitError(ErrorCodes.INVALID_CHAIN,
                "No RPC URL available for chain \"" + chain + "\". " +
                "Set REMITMD_RPC_URL or pass rpcUrl in the builder.",
                Map.of("chain", chain));
        }

        String jsonBody = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\"," +
            "\"params\":[{\"to\":\"" + usdcAddress + "\",\"data\":\"" + data + "\"},\"latest\"]}";

        try {
            HttpClient httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .build();
            HttpRequest req = HttpRequest.newBuilder()
                .uri(URI.create(rpc))
                .header("Content-Type", "application/json")
                .timeout(Duration.ofSeconds(15))
                .POST(HttpRequest.BodyPublishers.ofString(jsonBody))
                .build();
            HttpResponse<String> resp = httpClient.send(req, HttpResponse.BodyHandlers.ofString());

            // Parse "result" field from JSON-RPC response
            String body = resp.body();
            int resultIdx = body.indexOf("\"result\"");
            if (resultIdx == -1) {
                throw new RemitError(ErrorCodes.CHAIN_ERROR,
                    "RPC call to nonces() failed: no result in response.",
                    Map.of("response", body.length() > 200 ? body.substring(0, 200) : body));
            }
            // Extract hex value between quotes after "result":
            int colonIdx = body.indexOf(':', resultIdx);
            int startQuote = body.indexOf('"', colonIdx);
            int endQuote = body.indexOf('"', startQuote + 1);
            String hex = body.substring(startQuote + 1, endQuote);
            if (hex.startsWith("0x") || hex.startsWith("0X")) hex = hex.substring(2);
            return new BigInteger(hex, 16).longValueExact();
        } catch (RemitError e) {
            throw e;
        } catch (Exception e) {
            throw new RemitError(ErrorCodes.CHAIN_ERROR,
                "Failed to fetch USDC nonce via RPC: " + e.getMessage(),
                Map.of("rpc_url", rpc));
        }
    }

    // ─── Private crypto helpers ──────────────────────────────────────────────

    private static byte[] keccak256(byte[] input) {
        return org.web3j.crypto.Hash.sha3(input);
    }

    private static byte[] addressToBytes32(String address) {
        if (address == null || address.isBlank()) return new byte[32];
        String hex = address.startsWith("0x") ? address.substring(2) : address;
        if (hex.length() != 40) return new byte[32];
        byte[] addr = HexFormat.of().parseHex(hex);
        byte[] result = new byte[32];
        System.arraycopy(addr, 0, result, 12, 20);
        return result;
    }

    private static byte[] concatBytes(byte[]... arrays) {
        int total = 0;
        for (byte[] a : arrays) total += a.length;
        byte[] result = new byte[total];
        int pos = 0;
        for (byte[] a : arrays) {
            System.arraycopy(a, 0, result, pos, a.length);
            pos += a.length;
        }
        return result;
    }

    static void validateAmount(BigDecimal amount) {
        if (amount == null || amount.compareTo(BigDecimal.valueOf(0.000001)) < 0) {
            throw new RemitError(
                ErrorCodes.INVALID_AMOUNT,
                "Amount " + amount + " is below minimum 0.000001 USDC (1 base unit). " +
                "See remit.md/docs/amounts",
                Map.of("amount", String.valueOf(amount), "minimum", "0.000001")
            );
        }
        if (amount.compareTo(BigDecimal.valueOf(1_000_000)) > 0) {
            throw new RemitError(
                ErrorCodes.INVALID_AMOUNT,
                "Amount " + amount + " exceeds per-transaction maximum of 1,000,000 USDC. " +
                "See remit.md/docs/limits",
                Map.of("amount", amount.toPlainString(), "maximum", "1000000")
            );
        }
    }
}
