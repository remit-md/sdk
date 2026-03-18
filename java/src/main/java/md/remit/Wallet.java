package md.remit;

import md.remit.internal.ApiClient;
import md.remit.models.*;
import md.remit.signer.Signer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;

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

    private final ApiClient client;
    private final Signer signer;
    private final long chainId;
    private final String chain;
    private volatile ContractAddresses contractsCache;

    Wallet(ApiClient client, Signer signer, long chainId, String chain) {
        this.client = client;
        this.signer = signer;
        this.chainId = chainId;
        this.chain = chain;
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
        return client.get("/api/v0/wallet/balance", Balance.class);
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
        if (permit != null) body.put("permit", permit);
        return client.post("/api/v0/payments/direct", body, Transaction.class);
    }

    // ─── Transaction History ──────────────────────────────────────────────────

    /**
     * Returns paginated transaction history.
     *
     * @param page    1-based page number (default 1)
     * @param perPage items per page (default 50, max 200)
     */
    public TransactionList history(int page, int perPage) {
        return client.get("/api/v0/wallet/history?page=" + page + "&per_page=" + perPage, TransactionList.class);
    }

    /** Returns the first page of transaction history (50 items). */
    public TransactionList history() {
        return client.get("/api/v0/wallet/history", TransactionList.class);
    }

    // ─── Reputation ───────────────────────────────────────────────────────────

    /** Returns the on-chain reputation for a given address. */
    public Reputation reputation(String address) {
        validateAddress(address);
        return client.get("/api/v0/reputation/" + address, Reputation.class);
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

        client.post("/api/v0/invoices", invoiceBody, Map.class);

        // Step 2: fund the escrow.
        Map<String, Object> escrowBody = new java.util.HashMap<>();
        escrowBody.put("invoice_id", invoiceId);
        if (permit != null) escrowBody.put("permit", permit);

        return client.post("/api/v0/escrows", escrowBody, Escrow.class);
    }

    /** Releases escrow funds to the payee. */
    public Transaction releaseEscrow(String escrowId) {
        return client.post("/api/v0/escrows/" + escrowId + "/release",
            Map.of("escrow_id", escrowId), Transaction.class);
    }

    /** Releases a specific milestone within an escrow. */
    public Transaction releaseEscrowMilestone(String escrowId, String milestoneId) {
        return client.post("/api/v0/escrows/" + escrowId + "/release",
            Map.of("escrow_id", escrowId, "milestone_id", milestoneId), Transaction.class);
    }

    /** Cancels an escrow and returns funds to the payer. */
    public Transaction cancelEscrow(String escrowId) {
        return client.post("/api/v0/escrows/" + escrowId + "/cancel", null, Transaction.class);
    }

    /** Returns the current state of an escrow. */
    public Escrow getEscrow(String escrowId) {
        return client.get("/api/v0/escrows/" + escrowId, Escrow.class);
    }

    /** Signals the provider has started work on an escrow. */
    public Escrow claimStart(String escrowId) {
        return client.post("/api/v0/escrows/" + escrowId + "/claim-start", Map.of(), Escrow.class);
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
        long expiry = Instant.now().getEpochSecond() + expiresInSeconds;
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("chain", chain);
        body.put("provider", provider);
        body.put("limit_amount", limitAmount.toPlainString());
        body.put("per_unit", perUnit.toPlainString());
        body.put("expiry", expiry);
        if (permit != null) body.put("permit", permit);
        return client.post("/api/v0/tabs", body, Tab.class);
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
        return client.post("/api/v0/tabs/" + tabId + "/charge", body, TabCharge.class);
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
        return client.post("/api/v0/tabs/" + tabId + "/close", body, Tab.class);
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
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("chain", chain);
        body.put("payee", payee);
        body.put("rate_per_second", ratePerSecond.toPlainString());
        body.put("max_total", maxTotal.toPlainString());
        if (permit != null) body.put("permit", permit);
        return client.post("/api/v0/streams", body, Stream.class);
    }

    /** Closes a stream and settles on-chain (payer only). */
    public Stream closeStream(String streamId) {
        return client.post("/api/v0/streams/" + streamId + "/close", Map.of(), Stream.class);
    }

    /** Claims all vested stream payments (callable by recipient). */
    public Transaction withdrawStream(String streamId) {
        return client.post("/api/v0/streams/" + streamId + "/withdraw", null, Transaction.class);
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
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("chain", chain);
        body.put("amount", amount.toPlainString());
        body.put("task_description", taskDescription);
        body.put("deadline", deadline);
        body.put("max_attempts", maxAttempts);
        if (permit != null) body.put("permit", permit);
        return client.post("/api/v0/bounties", body, Bounty.class);
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
        return client.post("/api/v0/bounties/" + bountyId + "/submit", body, BountySubmission.class);
    }

    /**
     * Awards a bounty to a specific submission (poster-only).
     *
     * @param bountyId     bounty UUID
     * @param submissionId submission ID returned by {@link #submitBounty}
     */
    public Bounty awardBounty(String bountyId, int submissionId) {
        return client.post("/api/v0/bounties/" + bountyId + "/award",
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
        StringBuilder sb = new StringBuilder("/api/v0/bounties?limit=").append(limit);
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
        long expiry = Instant.now().getEpochSecond() + expiresIn;
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("chain", chain);
        body.put("provider", provider);
        body.put("amount", amount.toPlainString());
        body.put("expiry", expiry);
        if (permit != null) body.put("permit", permit);
        return client.post("/api/v0/deposits", body, Deposit.class);
    }

    /** Returns a deposit (provider-side, full refund to depositor). */
    public Deposit returnDeposit(String depositId) {
        return client.post("/api/v0/deposits/" + depositId + "/return", Map.of(), Deposit.class);
    }

    // ─── Analytics ────────────────────────────────────────────────────────────

    /**
     * Returns spending analytics.
     *
     * @param period "day", "week", "month", or "all"
     */
    public SpendingSummary spendingSummary(String period) {
        return client.get("/api/v0/wallet/spending?period=" + period, SpendingSummary.class);
    }

    /** Returns how much the agent can still spend under operator-set limits. */
    public Budget remainingBudget() {
        return client.get("/api/v0/wallet/budget", Budget.class);
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
            contractsCache = client.get("/api/v0/contracts", ContractAddresses.class);
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
        return client.post("/api/v0/mint",
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
        return client.post("/api/v0/webhooks", body, Webhook.class);
    }

    /** Registers a webhook for all chains. */
    public Webhook registerWebhook(String url, List<String> events) {
        return registerWebhook(url, events, null);
    }

    // ─── One-time operator links ──────────────────────────────────────────────

    /** Generates a one-time URL for the operator to fund this wallet. */
    public LinkResponse createFundLink() {
        return client.post("/api/v0/links/fund", Map.of(), LinkResponse.class);
    }

    /** Generates a one-time URL for the operator to withdraw funds. */
    public LinkResponse createWithdrawLink() {
        return client.post("/api/v0/links/withdraw", Map.of(), LinkResponse.class);
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
