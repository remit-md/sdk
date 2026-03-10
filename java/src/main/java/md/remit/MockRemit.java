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
        return new Wallet(mockClient, mockSigner, MOCK_CHAIN_ID);
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

    Escrow mockCreateEscrow(String payee, BigDecimal amount, String memo) {
        BigDecimal current = balance.get();
        if (current.compareTo(amount) < 0) {
            throw new RemitError(ErrorCodes.INSUFFICIENT_FUNDS,
                "Insufficient balance for escrow: have " + current + " USDC, need " + amount + " USDC.",
                Map.of("balance", current.toPlainString(), "amount", amount.toPlainString())
            );
        }
        balance.set(current.subtract(amount));
        Escrow e = new Escrow();
        e.id = "esc_" + counter.incrementAndGet();
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

    Tab mockCreateTab(String counterpart, BigDecimal limit) {
        Tab t = new Tab();
        t.id = "tab_" + counter.incrementAndGet();
        t.opener = MOCK_ADDRESS;
        t.counterpart = counterpart;
        t.limit = limit;
        t.used = BigDecimal.ZERO;
        t.status = "open";
        t.createdAt = Instant.now();
        tabs.put(t.id, t);
        return t;
    }

    TabDebit mockDebitTab(String tabId, BigDecimal amount, String memo) {
        Tab t = tabs.get(tabId);
        if (t == null) {
            throw new RemitError(ErrorCodes.TAB_NOT_FOUND, "Tab \"" + tabId + "\" not found.",
                Map.of("tab_id", tabId));
        }
        BigDecimal newUsed = t.used.add(amount);
        if (newUsed.compareTo(t.limit) > 0) {
            throw new RemitError(ErrorCodes.TAB_LIMIT_EXCEEDED,
                "Tab debit of " + amount + " USDC would exceed tab limit of " + t.limit + " USDC. " +
                "Used so far: " + t.used + " USDC.",
                Map.of("limit", t.limit.toPlainString(), "used", t.used.toPlainString(), "requested", amount.toPlainString())
            );
        }
        t.used = newUsed;
        TabDebit debit = new TabDebit();
        debit.id = "dbt_" + counter.incrementAndGet();
        debit.tabId = tabId;
        debit.amount = amount;
        debit.memo = memo;
        debit.cumulative = newUsed;
        debit.createdAt = Instant.now();
        return debit;
    }

    Transaction mockSettleTab(String tabId) {
        Tab t = tabs.get(tabId);
        if (t == null) {
            throw new RemitError(ErrorCodes.TAB_NOT_FOUND, "Tab \"" + tabId + "\" not found.",
                Map.of("tab_id", tabId));
        }
        t.status = "settled";
        Transaction tx = new Transaction();
        tx.id = "tx_" + counter.incrementAndGet();
        tx.txHash = "0x" + "d".repeat(64);
        tx.from = t.opener;
        tx.to = t.counterpart;
        tx.amount = t.used;
        tx.chainId = MOCK_CHAIN_ID;
        tx.createdAt = Instant.now();
        transactions.add(tx);
        return tx;
    }

    Bounty mockCreateBounty(BigDecimal award, String description) {
        Bounty b = new Bounty();
        b.id = "bty_" + counter.incrementAndGet();
        b.poster = MOCK_ADDRESS;
        b.award = award;
        b.description = description;
        b.status = "open";
        b.createdAt = Instant.now();
        bounties.put(b.id, b);
        return b;
    }

    Transaction mockAwardBounty(String bountyId, String winner) {
        Bounty b = bounties.get(bountyId);
        if (b == null) {
            throw new RemitError(ErrorCodes.BOUNTY_NOT_FOUND, "Bounty \"" + bountyId + "\" not found.",
                Map.of("bounty_id", bountyId));
        }
        b.status = "awarded";
        b.winner = winner;
        Transaction tx = new Transaction();
        tx.id = "tx_" + counter.incrementAndGet();
        tx.txHash = "0x" + "e".repeat(64);
        tx.from = b.poster;
        tx.to = winner;
        tx.amount = b.award;
        tx.chainId = MOCK_CHAIN_ID;
        tx.createdAt = Instant.now();
        transactions.add(tx);
        return tx;
    }

    Reputation mockReputation(String address) {
        Reputation r = new Reputation();
        r.address = address;
        r.score = 750;
        r.totalPaid = BigDecimal.valueOf(1000);
        r.totalReceived = BigDecimal.valueOf(500);
        r.transactionCount = 42;
        r.disputeRate = 0.0;
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

    // ─── Mock infrastructure ──────────────────────────────────────────────────

    /** Internal ApiClient that routes to mock handlers. */
    private static class MockApiClient extends ApiClient {

        private final MockRemit mock;

        MockApiClient(MockRemit mock) {
            super("http://mock.invalid", MockRemit.MOCK_CHAIN_ID, hash -> new byte[65]);
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
                String memo = (String) b.getOrDefault("memo", "");
                return (T) mock.mockPay(to, amount, memo);
            }
            if ("POST".equals(method) && "/api/v0/escrows".equals(path)) {
                String payee = (String) b.get("payee");
                BigDecimal amount = new BigDecimal((String) b.get("amount"));
                String memo = (String) b.getOrDefault("memo", "");
                return (T) mock.mockCreateEscrow(payee, amount, memo);
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
                String counterpart = (String) b.get("counterpart");
                BigDecimal limit = new BigDecimal((String) b.get("limit"));
                return (T) mock.mockCreateTab(counterpart, limit);
            }
            if ("POST".equals(method) && path.contains("/tabs/") && path.endsWith("/debit")) {
                String tabId = path.replace("/api/v0/tabs/", "").replace("/debit", "");
                BigDecimal amount = new BigDecimal((String) b.get("amount"));
                String memo = (String) b.getOrDefault("memo", "");
                return (T) mock.mockDebitTab(tabId, amount, memo);
            }
            if ("POST".equals(method) && path.contains("/tabs/") && path.endsWith("/settle")) {
                String tabId = path.replace("/api/v0/tabs/", "").replace("/settle", "");
                return (T) mock.mockSettleTab(tabId);
            }
            if ("POST".equals(method) && "/api/v0/bounties".equals(path)) {
                BigDecimal award = new BigDecimal((String) b.get("award"));
                String desc = (String) b.get("description");
                return (T) mock.mockCreateBounty(award, desc);
            }
            if ("POST".equals(method) && path.contains("/bounties/") && path.endsWith("/award")) {
                String bountyId = path.replace("/api/v0/bounties/", "").replace("/award", "");
                String winner = (String) b.get("winner");
                return (T) mock.mockAwardBounty(bountyId, winner);
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
