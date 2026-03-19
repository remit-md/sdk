package md.remit;

import md.remit.internal.ApiClient;
import md.remit.models.*;
import md.remit.signer.Signer;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * In-memory mock for testing agents that use remit.md.
 * Zero network, zero latency, deterministic — ideal for unit tests.
 *
 * <pre>{@code
 * MockRemit mock = new MockRemit();
 * Wallet wallet = mock.wallet();
 *
 * wallet.pay("0xRecipient...", new BigDecimal("1.50"));
 *
 * assertTrue(mock.wasPaid("0xRecipient...", new BigDecimal("1.50")));
 * assertEquals(new BigDecimal("1.50"), mock.totalPaidTo("0xRecipient..."));
 * }</pre>
 */
public class MockRemit {

    private static final String MOCK_ADDRESS = "0x0000000000000000000000000000000000000001";
    private static final long MOCK_CHAIN_ID = 84532L; // Base Sepolia

    private final AtomicReference<BigDecimal> balance;
    private final List<Transaction> transactions = new CopyOnWriteArrayList<>();
    private final Map<String, Escrow> escrows = new ConcurrentHashMap<>();
    private final Map<String, Tab> tabs = new ConcurrentHashMap<>();
    private final Map<String, Stream> streams = new ConcurrentHashMap<>();
    private final Map<String, Bounty> bounties = new ConcurrentHashMap<>();
    private final Map<String, Deposit> deposits = new ConcurrentHashMap<>();
    private final Map<String, Map<String, Object>> pendingInvoices = new ConcurrentHashMap<>();
    private final AtomicLong counter = new AtomicLong();

    /** Creates a mock with a default starting balance of 10,000 USDC. */
    public MockRemit() {
        this(BigDecimal.valueOf(10_000));
    }

    /** Creates a mock with a specific starting balance. */
    public MockRemit(BigDecimal startingBalance) {
        this.balance = new AtomicReference<>(startingBalance);
    }

    /**
     * Returns a {@link Wallet} backed by this mock. No private key required.
     * Safe to use in unit tests without any network or credentials.
     */
    public Wallet wallet() {
        MockApiClient mockClient = new MockApiClient(this);
        Signer mockSigner = new MockSigner();
        return new Wallet(mockClient, mockSigner, MOCK_CHAIN_ID, "base", null);
    }

    /** Overrides the mock's simulated USDC balance. */
    public void setBalance(BigDecimal amount) {
        balance.set(amount);
    }

    /** Clears all recorded state. Call between test cases. */
    public void reset() {
        balance.set(BigDecimal.valueOf(10_000));
        transactions.clear();
        escrows.clear();
        tabs.clear();
        streams.clear();
        bounties.clear();
        deposits.clear();
        pendingInvoices.clear();
        counter.set(0);
    }

    /** Returns all transactions recorded by this mock. */
    public List<Transaction> transactions() {
        return Collections.unmodifiableList(transactions);
    }

    /** Returns true if a payment of exactly {@code amount} USDC was sent to {@code recipient}. */
    public boolean wasPaid(String recipient, BigDecimal amount) {
        return transactions.stream()
            .anyMatch(tx -> tx.to.equalsIgnoreCase(recipient) && tx.amount.compareTo(amount) == 0);
    }

    /** Returns the sum of all USDC paid to {@code recipient}. */
    public BigDecimal totalPaidTo(String recipient) {
        return transactions.stream()
            .filter(tx -> tx.to.equalsIgnoreCase(recipient))
            .map(tx -> tx.amount)
            .reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    /** Returns the number of transactions recorded. */
    public int transactionCount() {
        return transactions.size();
    }

    // ─── Internal mock handlers ───────────────────────────────────────────────

    Balance mockBalance() {
        Balance b = new Balance();
        b.usdc = balance.get();
        b.address = MOCK_ADDRESS;
        b.chainId = MOCK_CHAIN_ID;
        b.updatedAt = Instant.now();
        return b;
    }

    Transaction mockPay(String to, BigDecimal amount, String memo) {
        BigDecimal current = balance.get();
        if (current.compareTo(amount) < 0) {
            throw new RemitError(ErrorCodes.INSUFFICIENT_FUNDS,
                "Insufficient balance: have " + current + " USDC, need " + amount + " USDC. " +
                "Call MockRemit.setBalance() to increase the balance.",
                Map.of("balance", current.toPlainString(), "amount", amount.toPlainString())
            );
        }
        balance.set(current.subtract(amount));
        Transaction tx = new Transaction();
        tx.id = "tx_" + counter.incrementAndGet();
        tx.txHash = "0x" + "a".repeat(64);
        tx.from = MOCK_ADDRESS;
        tx.to = to;
        tx.amount = amount;
        tx.fee = BigDecimal.valueOf(0.001);
        tx.memo = memo;
        tx.chainId = MOCK_CHAIN_ID;
        tx.createdAt = Instant.now();
        transactions.add(tx);
        return tx;
    }

    void mockCreateInvoice(Map<String, Object> body) {
        String invoiceId = (String) body.get("id");
        pendingInvoices.put(invoiceId, body);
    }

    Escrow mockCreateEscrow(String invoiceId) {
        Map<String, Object> inv = pendingInvoices.remove(invoiceId);
        if (inv == null) {
            throw new RemitError(ErrorCodes.ESCROW_NOT_FOUND,
                "Invoice \"" + invoiceId + "\" not found in mock.",
                Map.of("invoice_id", invoiceId));
        }
        String payee = (String) inv.get("to_agent");
        BigDecimal amount = new BigDecimal((String) inv.get("amount"));
        String memo = (String) inv.getOrDefault("task", "");

        BigDecimal current = balance.get();
        if (current.compareTo(amount) < 0) {
            throw new RemitError(ErrorCodes.INSUFFICIENT_FUNDS,
                "Insufficient balance for escrow: have " + current + " USDC, need " + amount + " USDC.",
                Map.of("balance", current.toPlainString(), "amount", amount.toPlainString())
            );
        }
        balance.set(current.subtract(amount));
        Escrow e = new Escrow();
        e.id = invoiceId;
        e.payer = MOCK_ADDRESS;
        e.payee = payee;
        e.amount = amount;
        e.fee = BigDecimal.valueOf(0.001);
        e.status = "funded";
        e.memo = memo;
        e.createdAt = Instant.now();
        escrows.put(e.id, e);
        return e;
    }

    Transaction mockReleaseEscrow(String escrowId) {
        Escrow e = escrows.get(escrowId);
        if (e == null) {
            throw new RemitError(ErrorCodes.ESCROW_NOT_FOUND,
                "Escrow \"" + escrowId + "\" not found. Verify the escrow ID is correct.",
                Map.of("escrow_id", escrowId)
            );
        }
        e.status = "released";
        Transaction tx = new Transaction();
        tx.id = "tx_" + counter.incrementAndGet();
        tx.txHash = "0x" + "b".repeat(64);
        tx.from = e.payer;
        tx.to = e.payee;
        tx.amount = e.amount;
        tx.chainId = MOCK_CHAIN_ID;
        tx.createdAt = Instant.now();
        transactions.add(tx);
        return tx;
    }

    Transaction mockCancelEscrow(String escrowId) {
        Escrow e = escrows.get(escrowId);
        if (e == null) {
            throw new RemitError(ErrorCodes.ESCROW_NOT_FOUND,
                "Escrow \"" + escrowId + "\" not found.",
                Map.of("escrow_id", escrowId)
            );
        }
        e.status = "cancelled";
        balance.set(balance.get().add(e.amount));
        Transaction tx = new Transaction();
        tx.id = "tx_" + counter.incrementAndGet();
        tx.txHash = "0x" + "c".repeat(64);
        tx.from = e.payer;
        tx.to = e.payer;
        tx.amount = e.amount;
        tx.chainId = MOCK_CHAIN_ID;
        tx.createdAt = Instant.now();
        transactions.add(tx);
        return tx;
    }

    Escrow mockGetEscrow(String escrowId) {
        Escrow e = escrows.get(escrowId);
        if (e == null) {
            throw new RemitError(ErrorCodes.ESCROW_NOT_FOUND, "Escrow \"" + escrowId + "\" not found.",
                Map.of("escrow_id", escrowId));
        }
        return e;
    }

    Tab mockCreateTab(String provider, BigDecimal limitAmount) {
        Tab t = new Tab();
        t.id = "tab_" + counter.incrementAndGet();
        t.opener = MOCK_ADDRESS;
        t.provider = provider;
        t.limitAmount = limitAmount;
        t.totalCharged = BigDecimal.ZERO;
        t.status = "open";
        t.createdAt = Instant.now();
        tabs.put(t.id, t);
        return t;
    }

    TabCharge mockChargeTab(String tabId, BigDecimal amount, BigDecimal cumulative, int callCount) {
        Tab t = tabs.get(tabId);
        if (t == null) {
            throw new RemitError(ErrorCodes.TAB_NOT_FOUND, "Tab \"" + tabId + "\" not found.",
                Map.of("tab_id", tabId));
        }
        if (cumulative.compareTo(t.limitAmount) > 0) {
            throw new RemitError(ErrorCodes.TAB_LIMIT_EXCEEDED,
                "Tab charge of " + amount + " USDC would exceed tab limit of " + t.limitAmount + " USDC.",
                Map.of("limit", t.limitAmount.toPlainString(), "requested", amount.toPlainString())
            );
        }
        t.totalCharged = cumulative;
        TabCharge charge = new TabCharge();
        charge.id = "chg_" + counter.incrementAndGet();
        charge.tabId = tabId;
        charge.amount = amount;
        charge.cumulative = cumulative;
        charge.callCount = callCount;
        charge.createdAt = Instant.now();
        return charge;
    }

    Tab mockCloseTab(String tabId) {
        Tab t = tabs.get(tabId);
        if (t == null) {
            throw new RemitError(ErrorCodes.TAB_NOT_FOUND, "Tab \"" + tabId + "\" not found.",
                Map.of("tab_id", tabId));
        }
        t.status = "closed";
        t.closedTxHash = "0x" + "d".repeat(64);
        Transaction tx = new Transaction();
        tx.id = "tx_" + counter.incrementAndGet();
        tx.txHash = t.closedTxHash;
        tx.from = t.opener;
        tx.to = t.provider;
        tx.amount = t.totalCharged;
        tx.chainId = MOCK_CHAIN_ID;
        tx.createdAt = Instant.now();
        transactions.add(tx);
        return t;
    }

    Bounty mockCreateBounty(BigDecimal amount, String taskDescription) {
        Bounty b = new Bounty();
        b.id = "bty_" + counter.incrementAndGet();
        b.poster = MOCK_ADDRESS;
        b.amount = amount;
        b.taskDescription = taskDescription;
        b.status = "open";
        b.createdAt = Instant.now();
        bounties.put(b.id, b);
        return b;
    }

    BountySubmission mockSubmitBounty(String bountyId, String evidenceHash) {
        Bounty b = bounties.get(bountyId);
        if (b == null) {
            throw new RemitError(ErrorCodes.BOUNTY_NOT_FOUND, "Bounty \"" + bountyId + "\" not found.",
                Map.of("bounty_id", bountyId));
        }
        BountySubmission sub = new BountySubmission();
        sub.id = (int) counter.incrementAndGet();
        sub.bountyId = bountyId;
        sub.submitter = MOCK_ADDRESS;
        return sub;
    }

    Bounty mockAwardBounty(String bountyId, int submissionId) {
        Bounty b = bounties.get(bountyId);
        if (b == null) {
            throw new RemitError(ErrorCodes.BOUNTY_NOT_FOUND, "Bounty \"" + bountyId + "\" not found.",
                Map.of("bounty_id", bountyId));
        }
        b.status = "awarded";
        Transaction tx = new Transaction();
        tx.id = "tx_" + counter.incrementAndGet();
        tx.txHash = "0x" + "e".repeat(64);
        tx.from = b.poster;
        tx.to = MOCK_ADDRESS;
        tx.amount = b.amount;
        tx.chainId = MOCK_CHAIN_ID;
        tx.createdAt = Instant.now();
        transactions.add(tx);
        return b;
    }

    Stream mockCreateStream(String payee, BigDecimal ratePerSecond, BigDecimal maxTotal) {
        Stream s = new Stream();
        s.id = "stm_" + counter.incrementAndGet();
        s.payer = MOCK_ADDRESS;
        s.payee = payee;
        s.ratePerSecond = ratePerSecond;
        s.maxTotal = maxTotal;
        s.withdrawn = BigDecimal.ZERO;
        s.vested = BigDecimal.ZERO;
        s.status = "active";
        s.createdAt = Instant.now();
        streams.put(s.id, s);
        return s;
    }

    Stream mockCloseStream(String streamId) {
        Stream s = streams.get(streamId);
        if (s == null) {
            throw new RemitError(ErrorCodes.STREAM_NOT_FOUND, "Stream \"" + streamId + "\" not found.",
                Map.of("stream_id", streamId));
        }
        s.status = "closed";
        s.closedTxHash = "0x" + "f".repeat(64);
        return s;
    }

    Deposit mockLockDeposit(String provider, BigDecimal amount) {
        BigDecimal current = balance.get();
        if (current.compareTo(amount) < 0) {
            throw new RemitError(ErrorCodes.INSUFFICIENT_FUNDS,
                "Insufficient balance for deposit.",
                Map.of("balance", current.toPlainString(), "amount", amount.toPlainString()));
        }
        balance.set(current.subtract(amount));
        Deposit d = new Deposit();
        d.id = "dep_" + counter.incrementAndGet();
        d.depositor = MOCK_ADDRESS;
        d.provider = provider;
        d.amount = amount;
        d.status = "locked";
        d.createdAt = Instant.now();
        deposits.put(d.id, d);
        return d;
    }

    Deposit mockReturnDeposit(String depositId) {
        Deposit d = deposits.get(depositId);
        if (d == null) {
            throw new RemitError(ErrorCodes.DEPOSIT_NOT_FOUND, "Deposit \"" + depositId + "\" not found.",
                Map.of("deposit_id", depositId));
        }
        d.status = "returned";
        balance.set(balance.get().add(d.amount));
        return d;
    }

    Reputation mockReputation(String address) {
        Reputation r = new Reputation();
        r.address = address;
        r.score = 750;
        r.totalPaid = BigDecimal.valueOf(1000);
        r.totalReceived = BigDecimal.valueOf(500);
        r.transactionCount = 42;
        r.memberSince = Instant.now().minusSeconds(30L * 24 * 3600);
        return r;
    }

    SpendingSummary mockSpendingSummary(String period) {
        SpendingSummary s = new SpendingSummary();
        s.address = MOCK_ADDRESS;
        s.period = period;
        s.totalSpent = totalPaidTo(null); // sum of all outgoing
        s.totalFees = BigDecimal.valueOf(0.001).multiply(BigDecimal.valueOf(transactions.size()));
        s.txCount = transactions.size();
        return s;
    }

    Budget mockBudget() {
        Budget b = new Budget();
        b.dailyLimit = BigDecimal.valueOf(10_000);
        b.dailyUsed = BigDecimal.ZERO;
        b.dailyRemaining = BigDecimal.valueOf(10_000);
        b.monthlyLimit = BigDecimal.valueOf(100_000);
        b.monthlyUsed = BigDecimal.ZERO;
        b.monthlyRemaining = BigDecimal.valueOf(100_000);
        b.perTxLimit = BigDecimal.valueOf(1_000);
        return b;
    }

    TransactionList mockHistory() {
        TransactionList list = new TransactionList();
        list.items = new ArrayList<>(transactions);
        list.total = transactions.size();
        list.page = 1;
        list.perPage = 50;
        list.hasMore = false;
        return list;
    }

    ContractAddresses mockContracts() {
        ContractAddresses c = new ContractAddresses();
        c.chainId = MOCK_CHAIN_ID;
        c.usdc = "0x0000000000000000000000000000000000000001";
        c.router = "0x0000000000000000000000000000000000000002";
        c.escrow = "0x0000000000000000000000000000000000000003";
        c.tab = "0x0000000000000000000000000000000000000004";
        c.stream = "0x0000000000000000000000000000000000000005";
        c.bounty = "0x0000000000000000000000000000000000000006";
        c.deposit = "0x0000000000000000000000000000000000000007";
        c.feeCalculator = "0x0000000000000000000000000000000000000008";
        c.keyRegistry = "0x0000000000000000000000000000000000000009";
        c.arbitration = "0x000000000000000000000000000000000000000a";
        return c;
    }

    MintResponse mockMint(double amount) {
        BigDecimal current = balance.get();
        balance.set(current.add(BigDecimal.valueOf(amount)));
        MintResponse r = new MintResponse();
        r.txHash = "0x" + "f".repeat(64);
        r.balance = balance.get();
        return r;
    }

    // ─── Mock infrastructure ──────────────────────────────────────────────────

    /** Internal ApiClient that routes to mock handlers. */
    private static class MockApiClient extends ApiClient {

        private final MockRemit mock;

        MockApiClient(MockRemit mock) {
            super("http://mock.invalid", MockRemit.MOCK_CHAIN_ID, "", hash -> new byte[65]);
            this.mock = mock;
        }

        @Override
        public <T> T get(String path, Class<T> responseType) {
            return dispatch("GET", path, null, responseType);
        }

        @Override
        public <T> T post(String path, Object body, Class<T> responseType) {
            return dispatch("POST", path, body, responseType);
        }

        @SuppressWarnings("unchecked")
        private <T> T dispatch(String method, String path, Object body, Class<T> responseType) {
            Map<String, Object> b = body instanceof Map ? (Map<String, Object>) body : Map.of();

            if ("GET".equals(method) && "/api/v0/wallet/balance".equals(path)) {
                return (T) mock.mockBalance();
            }
            if ("GET".equals(method) && "/api/v0/wallet/history".equals(path)) {
                return (T) mock.mockHistory();
            }
            if ("GET".equals(method) && path.startsWith("/api/v0/wallet/history")) {
                return (T) mock.mockHistory();
            }
            if ("GET".equals(method) && "/api/v0/wallet/budget".equals(path)) {
                return (T) mock.mockBudget();
            }
            if ("GET".equals(method) && path.startsWith("/api/v0/wallet/spending")) {
                String period = path.contains("period=") ? path.substring(path.indexOf("period=") + 7) : "month";
                return (T) mock.mockSpendingSummary(period);
            }
            if ("GET".equals(method) && path.startsWith("/api/v0/reputation/")) {
                String address = path.substring("/api/v0/reputation/".length());
                return (T) mock.mockReputation(address);
            }
            if ("GET".equals(method) && path.startsWith("/api/v0/escrows/")) {
                String escrowId = path.substring("/api/v0/escrows/".length());
                return (T) mock.mockGetEscrow(escrowId);
            }
            if ("POST".equals(method) && "/api/v0/payments/direct".equals(path)) {
                String to = (String) b.get("to");
                BigDecimal amount = new BigDecimal((String) b.get("amount"));
                String memo = (String) b.getOrDefault("task", "");
                return (T) mock.mockPay(to, amount, memo);
            }
            if ("POST".equals(method) && "/api/v0/invoices".equals(path)) {
                mock.mockCreateInvoice(b);
                return null;
            }
            if ("POST".equals(method) && "/api/v0/escrows".equals(path)) {
                String invoiceId = (String) b.get("invoice_id");
                return (T) mock.mockCreateEscrow(invoiceId);
            }
            if ("POST".equals(method) && path.endsWith("/claim-start")) {
                String escrowId = path.replace("/api/v0/escrows/", "").replace("/claim-start", "");
                return (T) mock.mockGetEscrow(escrowId);
            }
            if ("POST".equals(method) && path.endsWith("/release")) {
                String escrowId = path.replace("/api/v0/escrows/", "").replace("/release", "");
                return (T) mock.mockReleaseEscrow(escrowId);
            }
            if ("POST".equals(method) && path.endsWith("/cancel")) {
                String escrowId = path.replace("/api/v0/escrows/", "").replace("/cancel", "");
                return (T) mock.mockCancelEscrow(escrowId);
            }
            if ("POST".equals(method) && "/api/v0/tabs".equals(path)) {
                String provider = (String) b.get("provider");
                BigDecimal limitAmount = new BigDecimal((String) b.get("limit_amount"));
                return (T) mock.mockCreateTab(provider, limitAmount);
            }
            if ("POST".equals(method) && path.contains("/tabs/") && path.endsWith("/charge")) {
                String tabId = path.replace("/api/v0/tabs/", "").replace("/charge", "");
                BigDecimal amount = new BigDecimal((String) b.get("amount"));
                BigDecimal cumulative = new BigDecimal((String) b.get("cumulative"));
                int callCount = b.get("call_count") instanceof Number ? ((Number) b.get("call_count")).intValue() : 1;
                return (T) mock.mockChargeTab(tabId, amount, cumulative, callCount);
            }
            if ("POST".equals(method) && path.contains("/tabs/") && path.endsWith("/close")) {
                String tabId = path.replace("/api/v0/tabs/", "").replace("/close", "");
                return (T) mock.mockCloseTab(tabId);
            }
            if ("POST".equals(method) && "/api/v0/bounties".equals(path)) {
                BigDecimal amount = new BigDecimal((String) b.get("amount"));
                String desc = (String) b.get("task_description");
                return (T) mock.mockCreateBounty(amount, desc);
            }
            if ("POST".equals(method) && path.contains("/bounties/") && path.endsWith("/submit")) {
                String bountyId = path.replace("/api/v0/bounties/", "").replace("/submit", "");
                String evidenceHash = (String) b.get("evidence_hash");
                return (T) mock.mockSubmitBounty(bountyId, evidenceHash);
            }
            if ("POST".equals(method) && path.contains("/bounties/") && path.endsWith("/award")) {
                String bountyId = path.replace("/api/v0/bounties/", "").replace("/award", "");
                int submissionId = b.get("submission_id") instanceof Number ? ((Number) b.get("submission_id")).intValue() : 0;
                return (T) mock.mockAwardBounty(bountyId, submissionId);
            }
            if ("POST".equals(method) && "/api/v0/streams".equals(path)) {
                String payee = (String) b.get("payee");
                BigDecimal rate = new BigDecimal((String) b.get("rate_per_second"));
                BigDecimal maxTotal = new BigDecimal((String) b.get("max_total"));
                return (T) mock.mockCreateStream(payee, rate, maxTotal);
            }
            if ("POST".equals(method) && path.contains("/streams/") && path.endsWith("/close")) {
                String streamId = path.replace("/api/v0/streams/", "").replace("/close", "");
                return (T) mock.mockCloseStream(streamId);
            }
            if ("POST".equals(method) && "/api/v0/deposits".equals(path)) {
                String provider = (String) b.get("provider");
                BigDecimal amount = new BigDecimal((String) b.get("amount"));
                return (T) mock.mockLockDeposit(provider, amount);
            }
            if ("POST".equals(method) && path.contains("/deposits/") && path.endsWith("/return")) {
                String depositId = path.replace("/api/v0/deposits/", "").replace("/return", "");
                return (T) mock.mockReturnDeposit(depositId);
            }
            if ("GET".equals(method) && "/api/v0/contracts".equals(path)) {
                return (T) mock.mockContracts();
            }
            if ("POST".equals(method) && "/api/v0/mint".equals(path)) {
                double amount = b.get("amount") instanceof Number ? ((Number) b.get("amount")).doubleValue() : 0.0;
                return (T) mock.mockMint(amount);
            }
            // Permissive: unrecognized routes succeed with null
            return null;
        }
    }

    /** Mock signer that returns a zero signature. */
    private static class MockSigner implements Signer {
        @Override
        public byte[] sign(byte[] hash) {
            return new byte[65];
        }

        @Override
        public String address() {
            return MOCK_ADDRESS;
        }
    }
}
