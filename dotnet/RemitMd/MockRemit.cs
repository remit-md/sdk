using System.Text.Json;

namespace RemitMd;

/// <summary>
/// In-memory mock for testing agents that use remit.md.
/// Zero network calls, deterministic, sub-millisecond.
///
/// <example>
/// <code>
/// var mock = new MockRemit();
/// var wallet = mock.Wallet();
///
/// var tx = await wallet.PayAsync("0x000000000000000000000000000000000000dEaD", 1.50m);
/// Assert.True(mock.WasPaid("0x000000000000000000000000000000000000dEaD", 1.50m));
/// </code>
/// </example>
/// </summary>
public sealed class MockRemit
{
    private readonly object _lock = new();
    private readonly List<Transaction> _transactions = [];
    private readonly Dictionary<string, Escrow> _escrows = [];
    private readonly Dictionary<string, Tab> _tabs = [];
    private readonly Dictionary<string, Stream> _streams = [];
    private readonly Dictionary<string, Bounty> _bounties = [];
    private readonly Dictionary<string, Deposit> _deposits = [];
    private decimal _balance;

    private static readonly string MockAddress = "0xMock0000000000000000000000000000000000Mock";

    /// <summary>Creates a MockRemit with a starting balance (default: 10,000 USDC).</summary>
    public MockRemit(decimal startingBalance = 10_000m) => _balance = startingBalance;

    /// <summary>Returns a <see cref="Wallet"/> backed by this mock. No private key needed.</summary>
    public Wallet Wallet() => new(new MockTransport(this), new MockSigner(), 84532);

    // ─── Inspection helpers ───────────────────────────────────────────────────

    /// <summary>Returns true if a payment of exactly <paramref name="amount"/> was sent to <paramref name="recipient"/>.</summary>
    public bool WasPaid(string recipient, decimal amount)
    {
        lock (_lock)
            return _transactions.Any(t =>
                string.Equals(t.To, recipient, StringComparison.OrdinalIgnoreCase) &&
                t.Amount == amount);
    }

    /// <summary>Total USDC sent to <paramref name="recipient"/> across all payments.</summary>
    public decimal TotalPaidTo(string recipient)
    {
        lock (_lock)
            return _transactions
                .Where(t => string.Equals(t.To, recipient, StringComparison.OrdinalIgnoreCase))
                .Sum(t => t.Amount);
    }

    /// <summary>All transactions recorded since the last <see cref="Reset"/>.</summary>
    public IReadOnlyList<Transaction> Transactions
    {
        get { lock (_lock) return _transactions.ToList(); }
    }

    /// <summary>Current simulated balance.</summary>
    public decimal Balance
    {
        get { lock (_lock) return _balance; }
    }

    /// <summary>Sets the simulated USDC balance. Useful for testing insufficient-funds scenarios.</summary>
    public void SetBalance(decimal amount)
    {
        lock (_lock) _balance = amount;
    }

    /// <summary>Clears all recorded state. Call between test cases.</summary>
    public void Reset()
    {
        lock (_lock)
        {
            _transactions.Clear();
            _escrows.Clear();
            _tabs.Clear();
            _streams.Clear();
            _bounties.Clear();
            _deposits.Clear();
            _balance = 10_000m;
        }
    }

    // ─── Internal mock transport ──────────────────────────────────────────────

    private sealed class MockTransport : IRemitTransport
    {
        private readonly MockRemit _mock;
        public MockTransport(MockRemit mock) => _mock = mock;

        public Task<T> GetAsync<T>(string path, CancellationToken ct)
        {
            object result = path switch
            {
                var p when p.StartsWith("/api/v0/status/") => (object)new Balance(
                    _mock._balance, MockAddress, ChainId.BaseSepolia, DateTimeOffset.UtcNow),

                "/api/v0/invoices" =>
                    new TransactionList(_mock._transactions.ToList(), _mock._transactions.Count, 1, 20, false),

                var p when p.StartsWith("/api/v0/reputation/") => new Reputation(
                    MockAddress, 750, _mock._transactions.Sum(t => t.Amount), 0m,
                    _mock._transactions.Count, DateTimeOffset.UtcNow.AddDays(-30)),

                var p when p.StartsWith("/api/v0/escrows/") =>
                    _mock._escrows.TryGetValue(PathId(p), out var e)
                        ? (object)e
                        : throw new RemitError(ErrorCodes.EscrowNotFound, $"Escrow not found: {PathId(p)}"),

                _ => throw new RemitError(ErrorCodes.ServerError, $"Mock: unhandled GET {path}"),
            };

            return Task.FromResult(Reserialize<T>(result));
        }

        public Task<T> PostAsync<T>(string path, object body, CancellationToken ct)
        {
            var now = DateTimeOffset.UtcNow;
            var id  = Guid.NewGuid().ToString("N")[..16];

            object result = path switch
            {
                "/api/v0/payments/direct"              => HandlePay(body, id, now),

                "/api/v0/escrows"                      => HandleCreateEscrow(body, id, now),
                var p when p.EndsWith("/release")      => HandleEscrowAction(p, "released"),
                var p when p.EndsWith("/cancel")       => HandleEscrowAction(p, "cancelled"),

                "/api/v0/tabs"                         => HandleCreateTab(body, id, now),
                var p when p.EndsWith("/charge")       => HandleTabDebit(p, body, id),
                var p when p.StartsWith("/api/v0/tabs/") && p.EndsWith("/close")
                                                       => HandleTabSettle(p, id, now),

                "/api/v0/streams"                      => HandleCreateStream(body, id, now),
                var p when p.EndsWith("/withdraw")     => HandleStreamWithdraw(p, id, now),

                "/api/v0/bounties"                     => HandleCreateBounty(body, id, now),
                var p when p.EndsWith("/award")        => HandleBountyAward(p, body, id, now),

                "/api/v0/deposits"                     => HandleCreateDeposit(body, id, now),
                "/api/v0/invoices"                     => HandleCreateIntent(body, id, now),

                _ => throw new RemitError(ErrorCodes.ServerError, $"Mock: unhandled POST {path}"),
            };

            return Task.FromResult(Reserialize<T>(result));
        }

        // ── Payment ──────────────────────────────────────────────────────────

        private Transaction HandlePay(object body, string id, DateTimeOffset now)
        {
            var (to, amount, memo) = ExtractPayBody(body);

            lock (_mock._lock)
            {
                if (_mock._balance < amount)
                    throw new RemitError(ErrorCodes.InsufficientFunds,
                        $"Insufficient funds: balance is {_mock._balance:F6} USDC but payment requires {amount:F6} USDC. " +
                        "Use mock.SetBalance() to adjust the mock balance in tests.",
                        new Dictionary<string, object>
                        {
                            ["balance"]  = _mock._balance,
                            ["required"] = amount,
                        });

                _mock._balance -= amount;
                var fee = Math.Round(amount * 0.001m, 6); // 0.1% fee
                var tx  = new Transaction(id, "0x" + id, MockAddress, to, amount, fee, memo,
                    ChainId.BaseSepolia, 1_000_000ul, now);
                _mock._transactions.Add(tx);
                return tx;
            }
        }

        // ── Escrow ───────────────────────────────────────────────────────────

        private Escrow HandleCreateEscrow(object body, string id, DateTimeOffset now)
        {
            var d    = Deserialize(body);
            var to   = d.GetValueOrDefault("payee")?.ToString() ?? MockAddress;
            var amt  = decimal.Parse(d.GetValueOrDefault("amount")?.ToString() ?? "0");
            var memo = d.GetValueOrDefault("memo")?.ToString() ?? "";

            lock (_mock._lock)
            {
                if (_mock._balance < amt)
                    throw new RemitError(ErrorCodes.InsufficientFunds,
                        $"Insufficient funds for escrow: balance is {_mock._balance:F6} USDC.");

                _mock._balance -= amt;
                var escrow = new Escrow(id, MockAddress, to, amt, Math.Round(amt * 0.001m, 6),
                    EscrowStatus.Funded, memo, null, null, null, now);
                _mock._escrows[id] = escrow;
                return escrow;
            }
        }

        private Transaction HandleEscrowAction(string path, string action)
        {
            var escrowId = PathId(path.Replace("/release", "").Replace("/cancel", ""));
            lock (_mock._lock)
            {
                if (!_mock._escrows.TryGetValue(escrowId, out var escrow))
                    throw new RemitError(ErrorCodes.EscrowNotFound, $"Escrow not found: {escrowId}");

                if (escrow.Status == EscrowStatus.Released || escrow.Status == EscrowStatus.Cancelled)
                    throw new RemitError(ErrorCodes.EscrowAlreadyClosed,
                        $"Escrow {escrowId} is already {escrow.Status.ToString().ToLower()}.");

                var newStatus = action == "released" ? EscrowStatus.Released : EscrowStatus.Cancelled;
                if (action == "cancelled") _mock._balance += escrow.Amount; // refund
                _mock._escrows[escrowId] = escrow with { Status = newStatus };

                var txId = Guid.NewGuid().ToString("N")[..16];
                return new Transaction(txId, "0x" + txId, MockAddress,
                    action == "released" ? escrow.Payee : MockAddress,
                    escrow.Amount, 0m, $"escrow {action}", ChainId.BaseSepolia,
                    1_000_001ul, DateTimeOffset.UtcNow);
            }
        }

        // ── Tab ──────────────────────────────────────────────────────────────

        private Tab HandleCreateTab(object body, string id, DateTimeOffset now)
        {
            var d     = Deserialize(body);
            var cp    = d.GetValueOrDefault("counterpart")?.ToString() ?? "0x0";
            var limit = decimal.Parse(d.GetValueOrDefault("limit")?.ToString() ?? "0");

            var tab = new Tab(id, MockAddress, cp, limit, 0m, limit, TabStatus.Open, now, null);
            lock (_mock._lock) _mock._tabs[id] = tab;
            return tab;
        }

        private TabDebit HandleTabDebit(string path, object body, string id)
        {
            var tabId  = PathId(path.Replace("/charge", ""));
            var d      = Deserialize(body);
            var amount = decimal.Parse(d.GetValueOrDefault("amount")?.ToString() ?? "0");
            var memo   = d.GetValueOrDefault("memo")?.ToString() ?? "";

            lock (_mock._lock)
            {
                if (!_mock._tabs.TryGetValue(tabId, out var tab))
                    throw new RemitError(ErrorCodes.TabNotFound, $"Tab not found: {tabId}");
                if (tab.Status != TabStatus.Open)
                    throw new RemitError(ErrorCodes.TabAlreadyClosed, $"Tab {tabId} is not open.");
                if (tab.Remaining < amount)
                    throw new RemitError(ErrorCodes.TabLimitExceeded,
                        $"Tab limit exceeded: remaining {tab.Remaining:F6}, requested {amount:F6}.");

                _mock._tabs[tabId] = tab with { Used = tab.Used + amount, Remaining = tab.Remaining - amount };
                return new TabDebit(tabId, amount, memo, (ulong)_mock._tabs[tabId].Used.GetHashCode(), "0xsig-" + id);
            }
        }

        private Transaction HandleTabSettle(string path, string id, DateTimeOffset now)
        {
            var tabId = PathId(path.Replace("/close", ""));
            lock (_mock._lock)
            {
                if (!_mock._tabs.TryGetValue(tabId, out var tab))
                    throw new RemitError(ErrorCodes.TabNotFound, $"Tab not found: {tabId}");
                _mock._tabs[tabId] = tab with { Status = TabStatus.Settled };
                return new Transaction(id, "0x" + id, MockAddress, tab.Counterpart,
                    tab.Used, Math.Round(tab.Used * 0.001m, 6), "tab settle",
                    ChainId.BaseSepolia, 1_000_002ul, now);
            }
        }

        // ── Stream ───────────────────────────────────────────────────────────

        private Stream HandleCreateStream(object body, string id, DateTimeOffset now)
        {
            var d    = Deserialize(body);
            var to   = d.GetValueOrDefault("recipient")?.ToString() ?? "0x0";
            var rate = decimal.Parse(d.GetValueOrDefault("rate_per_sec")?.ToString() ?? "0");
            var dep  = decimal.Parse(d.GetValueOrDefault("deposit")?.ToString() ?? "0");

            lock (_mock._lock)
            {
                if (_mock._balance < dep)
                    throw new RemitError(ErrorCodes.InsufficientFunds,
                        $"Insufficient funds for stream deposit: balance {_mock._balance:F6}, deposit {dep:F6}.");
                _mock._balance -= dep;
                var stream = new Stream(id, MockAddress, to, rate, dep, 0m, StreamStatus.Active, now, null);
                _mock._streams[id] = stream;
                return stream;
            }
        }

        private Transaction HandleStreamWithdraw(string path, string id, DateTimeOffset now)
        {
            var streamId = PathId(path.Replace("/withdraw", ""));
            lock (_mock._lock)
            {
                if (!_mock._streams.TryGetValue(streamId, out var stream))
                    throw new RemitError(ErrorCodes.StreamNotFound, $"Stream not found: {streamId}");
                if (stream.Status != StreamStatus.Active)
                    throw new RemitError(ErrorCodes.StreamNotActive, $"Stream {streamId} is not active.");

                // Simulate 5 minutes of accrued earnings
                var accrued = stream.RatePerSec * 300m;
                if (accrued <= 0)
                    throw new RemitError(ErrorCodes.NothingToWithdraw, "Nothing to withdraw yet.");

                _mock._streams[streamId] = stream with { Withdrawn = stream.Withdrawn + accrued };
                return new Transaction(id, "0x" + id, MockAddress, stream.Recipient,
                    accrued, 0m, "stream withdraw", ChainId.BaseSepolia, 1_000_003ul, now);
            }
        }

        // ── Bounty ───────────────────────────────────────────────────────────

        private Bounty HandleCreateBounty(object body, string id, DateTimeOffset now)
        {
            var d     = Deserialize(body);
            var award = decimal.Parse(d.GetValueOrDefault("award")?.ToString() ?? "0");
            var desc  = d.GetValueOrDefault("description")?.ToString() ?? "";

            lock (_mock._lock)
            {
                if (_mock._balance < award)
                    throw new RemitError(ErrorCodes.InsufficientFunds,
                        $"Insufficient funds for bounty: balance {_mock._balance:F6}, award {award:F6}.");
                _mock._balance -= award;
                var bounty = new Bounty(id, MockAddress, award, desc, BountyStatus.Open, null, null, now);
                _mock._bounties[id] = bounty;
                return bounty;
            }
        }

        private Transaction HandleBountyAward(string path, object body, string id, DateTimeOffset now)
        {
            var bountyId = PathId(path.Replace("/award", ""));
            var d        = Deserialize(body);
            var winner   = d.GetValueOrDefault("winner")?.ToString() ?? "0x0";

            lock (_mock._lock)
            {
                if (!_mock._bounties.TryGetValue(bountyId, out var bounty))
                    throw new RemitError(ErrorCodes.BountyNotFound, $"Bounty not found: {bountyId}");
                if (bounty.Status != BountyStatus.Open)
                    throw new RemitError(ErrorCodes.BountyAlreadyClosed, $"Bounty {bountyId} is not open.");

                _mock._bounties[bountyId] = bounty with { Status = BountyStatus.Awarded, Winner = winner };
                return new Transaction(id, "0x" + id, MockAddress, winner,
                    bounty.Award, 0m, "bounty award", ChainId.BaseSepolia, 1_000_004ul, now);
            }
        }

        // ── Deposit ──────────────────────────────────────────────────────────

        private Deposit HandleCreateDeposit(object body, string id, DateTimeOffset now)
        {
            var d    = Deserialize(body);
            var bene = d.GetValueOrDefault("beneficiary")?.ToString() ?? "0x0";
            var amt  = decimal.Parse(d.GetValueOrDefault("amount")?.ToString() ?? "0");

            lock (_mock._lock)
            {
                if (_mock._balance < amt)
                    throw new RemitError(ErrorCodes.InsufficientFunds,
                        $"Insufficient funds for deposit: balance {_mock._balance:F6}, amount {amt:F6}.");
                _mock._balance -= amt;
                var deposit = new Deposit(id, MockAddress, bene, amt, DepositStatus.Locked, null, now);
                _mock._deposits[id] = deposit;
                return deposit;
            }
        }

        // ── Intent ───────────────────────────────────────────────────────────

        private Intent HandleCreateIntent(object body, string id, DateTimeOffset now)
        {
            var d   = Deserialize(body);
            var to  = d.GetValueOrDefault("to")?.ToString() ?? "0x0";
            var amt = decimal.Parse(d.GetValueOrDefault("amount")?.ToString() ?? "0");
            var typ = d.GetValueOrDefault("type")?.ToString() ?? "direct";
            return new Intent(id, MockAddress, to, amt, typ, now.AddMinutes(5), now);
        }

        // ── Helpers ──────────────────────────────────────────────────────────

        private static string PathId(string path) =>
            path.TrimEnd('/').Split('/').Last();

        private static Dictionary<string, object?> Deserialize(object body)
        {
            var json = JsonSerializer.Serialize(body);
            return JsonSerializer.Deserialize<Dictionary<string, object?>>(json)
                   ?? [];
        }

        private static T Reserialize<T>(object obj)
        {
            var json = JsonSerializer.Serialize(obj);
            return JsonSerializer.Deserialize<T>(json)!;
        }

        private static (string to, decimal amount, string memo) ExtractPayBody(object body)
        {
            var d = Deserialize(body);
            return (
                d.GetValueOrDefault("to")?.ToString() ?? MockAddress,
                decimal.Parse(d.GetValueOrDefault("amount")?.ToString() ?? "0"),
                d.GetValueOrDefault("task")?.ToString() ?? ""
            );
        }
    }

    // ─── Mock signer (no real key needed) ────────────────────────────────────

    private sealed class MockSigner : IRemitSigner
    {
        public string Address => "0x1234567890abcdef1234567890abcdef12345678";
        public string Sign(byte[] hash) => "0x" + Convert.ToHexString(hash).ToLower() + "00";
    }
}
