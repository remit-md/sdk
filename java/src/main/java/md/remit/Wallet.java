package md.remit;

import md.remit.internal.ApiClient;
import md.remit.models.*;
import md.remit.signer.Signer;

import java.math.BigDecimal;
import java.time.Duration;
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

    Wallet(ApiClient client, Signer signer, long chainId) {
        this.client = client;
        this.signer = signer;
        this.chainId = chainId;
    }

    /** The Ethereum address (0x-prefixed) of this wallet. */
    public String address() {
        return signer.address();
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
        return pay(to, amount, null);
    }

    /** Sends a direct USDC payment with a memo string. */
    public Transaction pay(String to, BigDecimal amount, String memo) {
        validateAddress(to);
        validateAmount(amount);
        return client.post("/api/v0/payments/direct",
            Map.of("to", to, "amount", amount.toPlainString(), "task", memo != null ? memo : ""),
            Transaction.class);
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
        return createEscrow(payee, amount, null, null, null, null);
    }

    /** Creates an escrow with an optional memo and expiry. */
    public Escrow createEscrow(String payee, BigDecimal amount, String memo, Duration expiresIn) {
        return createEscrow(payee, amount, memo, expiresIn, null, null);
    }

    /** Creates an escrow with milestone-based partial payments. */
    public Escrow createEscrow(String payee, BigDecimal amount, String memo, Duration expiresIn,
                                List<Escrow.Milestone> milestones, List<Escrow.Split> splits) {
        validateAddress(payee);
        validateAmount(amount);

        Map<String, Object> body = new java.util.HashMap<>();
        body.put("payee", payee);
        body.put("amount", amount.toPlainString());
        if (memo != null) body.put("memo", memo);
        if (expiresIn != null) body.put("expires_in_seconds", (int) expiresIn.toSeconds());
        if (milestones != null && !milestones.isEmpty()) body.put("milestones", milestones);
        if (splits != null && !splits.isEmpty()) body.put("splits", splits);

        return client.post("/api/v0/escrows", body, Escrow.class);
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

    // ─── Tab ──────────────────────────────────────────────────────────────────

    /**
     * Opens a payment channel for batched micro-payments.
     *
     * @param counterpart the other party's address
     * @param limit       maximum USDC that can be charged through this tab
     */
    public Tab createTab(String counterpart, BigDecimal limit) {
        return createTab(counterpart, limit, null);
    }

    /** Opens a tab with an explicit expiry. */
    public Tab createTab(String counterpart, BigDecimal limit, Duration expiresIn) {
        validateAddress(counterpart);
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("counterpart", counterpart);
        body.put("limit", limit.toPlainString());
        if (expiresIn != null) body.put("expires_in_seconds", (int) expiresIn.toSeconds());
        return client.post("/api/v0/tabs", body, Tab.class);
    }

    /** Charges the given amount from an open tab (off-chain, signed). */
    public TabDebit debitTab(String tabId, BigDecimal amount, String memo) {
        return client.post("/api/v0/tabs/" + tabId + "/debit",
            Map.of("tab_id", tabId, "amount", amount.toPlainString(), "memo", memo != null ? memo : ""),
            TabDebit.class);
    }

    /** Closes the tab and settles all charges on-chain. */
    public Transaction settleTab(String tabId) {
        return client.post("/api/v0/tabs/" + tabId + "/settle", null, Transaction.class);
    }

    // ─── Stream ───────────────────────────────────────────────────────────────

    /**
     * Starts a per-second USDC payment stream.
     *
     * @param recipient  receiving address
     * @param ratePerSec USDC per second (e.g., 0.0001)
     * @param deposit    initial deposit locking funds for streaming
     */
    public Stream createStream(String recipient, BigDecimal ratePerSec, BigDecimal deposit) {
        validateAddress(recipient);
        return client.post("/api/v0/streams",
            Map.of("recipient", recipient, "rate_per_sec", ratePerSec.toPlainString(),
                   "deposit", deposit.toPlainString()),
            Stream.class);
    }

    /** Claims all vested stream payments (callable by recipient). */
    public Transaction withdrawStream(String streamId) {
        return client.post("/api/v0/streams/" + streamId + "/withdraw", null, Transaction.class);
    }

    // ─── Bounty ───────────────────────────────────────────────────────────────

    /**
     * Posts a USDC bounty for task completion.
     *
     * @param award       amount awarded to the winner
     * @param description human-readable task description
     */
    public Bounty createBounty(BigDecimal award, String description) {
        return createBounty(award, description, null);
    }

    /** Posts a bounty with an expiry deadline. */
    public Bounty createBounty(BigDecimal award, String description, Duration expiresIn) {
        validateAmount(award);
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("award", award.toPlainString());
        body.put("description", description);
        if (expiresIn != null) body.put("expires_in_seconds", (int) expiresIn.toSeconds());
        return client.post("/api/v0/bounties", body, Bounty.class);
    }

    /** Pays the bounty to the winner. */
    public Transaction awardBounty(String bountyId, String winner) {
        validateAddress(winner);
        return client.post("/api/v0/bounties/" + bountyId + "/award",
            Map.of("bounty_id", bountyId, "winner", winner), Transaction.class);
    }

    // ─── Deposit ──────────────────────────────────────────────────────────────

    /**
     * Locks a security deposit with a beneficiary.
     *
     * @param beneficiary address that can claim the deposit on default
     * @param amount      USDC to lock
     * @param expiresIn   how long the deposit remains locked
     */
    public Deposit lockDeposit(String beneficiary, BigDecimal amount, Duration expiresIn) {
        validateAddress(beneficiary);
        validateAmount(amount);
        return client.post("/api/v0/deposits",
            Map.of("beneficiary", beneficiary,
                   "amount", amount.toPlainString(),
                   "expires_in_seconds", (int) expiresIn.toSeconds()),
            Deposit.class);
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
