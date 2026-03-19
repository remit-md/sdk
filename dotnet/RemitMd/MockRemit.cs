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
    private readonly Dictionary<string, Dictionary<string, object?>> _pendingInvoices = [];
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
            _pendingInvoices.Clear();
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

                "/api/v0/contracts" => new ContractAddresses(
                    84532,
                    "0x142aD61B8d2edD6b3807D9266866D97C35Ee0317",
                    "0xb3E96ebE54138d1c0caea00Ae098309C7E0138eC",
                    "0x9AC531dd432d5dcF637D288290E5A23F2eE36594",
                    "0xE6D1Bc6dE70Dbc432d5fFbE8Bcd2C578C49Eb23b",
                    "0x9e54bFB3Dcd1dB1235655a4D22b1c1d74b62C883",
                    "0x2D08DD3093De3F22f85300330671122300F1e01b",
                    "0x5DC44bd61729Dc06187D0F2B1612ea21e69B6a52",
                    "0x853CFc2387C184E4492892475adfc19A23FF2e4F",
                    "0x97ff63c9E24Fc074023F5d1251E544dCDaC93886",
                    "0x3b2C97AafCdFBD5F6C9cF86dDa684Faa248008B1"),

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

                "/api/v0/invoices"                     => HandleCreateInvoice(body),
                "/api/v0/escrows"                      => HandleCreateEscrow(body, now),
                var p when p.EndsWith("/claim-start")  => HandleClaimStart(p),
                var p when p.EndsWith("/release")      => HandleEscrowAction(p, "released"),
                var p when p.EndsWith("/cancel")       => HandleEscrowAction(p, "cancelled"),

                "/api/v0/tabs"                         => HandleCreateTab(body, id, now),
                var p when p.StartsWith("/api/v0/tabs/") && p.EndsWith("/charge")
                                                       => HandleTabCharge(p, body, id),
                var p when p.StartsWith("/api/v0/tabs/") && p.EndsWith("/close")
                                                       => HandleTabClose(p, body, id, now),

                "/api/v0/streams"                      => HandleCreateStream(body, id, now),
                var p when p.StartsWith("/api/v0/streams/") && p.EndsWith("/close")
                                                       => HandleStreamClose(p, id, now),

                "/api/v0/bounties"                     => HandleCreateBounty(body, id, now),
                var p when p.StartsWith("/api/v0/bounties/") && p.EndsWith("/submit")
                                                       => HandleBountySubmit(p, body, id),
                var p when p.StartsWith("/api/v0/bounties/") && p.EndsWith("/award")
                                                       => HandleBountyAward(p, body, id, now),

                "/api/v0/deposits"                     => HandleCreateDeposit(body, id, now),
                var p when p.StartsWith("/api/v0/deposits/") && p.EndsWith("/return")
                                                       => HandleDepositReturn(p, id, now),

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

        private object HandleCreateInvoice(object body)
        {
            var d = Deserialize(body);
            var invoiceId = d.GetValueOrDefault("id")?.ToString() ?? "";
            lock (_mock._lock)
            {
                _mock._pendingInvoices[invoiceId] = d;
            }
            return new { id = invoiceId, status = "pending" };
        }

        private Escrow HandleCreateEscrow(object body, DateTimeOffset now)
        {
            var d = Deserialize(body);
            var invoiceId = d.GetValueOrDefault("invoice_id")?.ToString() ?? "";
            lock (_mock._lock)
            {
                if (!_mock._pendingInvoices.TryGetValue(invoiceId, out var inv))
                    throw new RemitError(ErrorCodes.EscrowNotFound, $"Invoice not found: {invoiceId}");
                _mock._pendingInvoices.Remove(invoiceId);

                var to   = inv.GetValueOrDefault("to_agent")?.ToString() ?? MockAddress;
                var amt  = decimal.Parse(inv.GetValueOrDefault("amount")?.ToString() ?? "0");
                var memo = inv.GetValueOrDefault("task")?.ToString() ?? "";

                if (_mock._balance < amt)
                    throw new RemitError(ErrorCodes.InsufficientFunds,
                        $"Insufficient funds for escrow: balance is {_mock._balance:F6} USDC.");

                _mock._balance -= amt;
                var escrow = new Escrow(invoiceId, MockAddress, to, amt, Math.Round(amt * 0.001m, 6),
                    EscrowStatus.Funded, memo, null, null, null, now);
                _mock._escrows[invoiceId] = escrow;
                return escrow;
            }
        }

        private Escrow HandleClaimStart(string path)
        {
            var escrowId = PathId(path.Replace("/claim-start", ""));
            lock (_mock._lock)
            {
                if (!_mock._escrows.TryGetValue(escrowId, out var escrow))
                    throw new RemitError(ErrorCodes.EscrowNotFound, $"Escrow not found: {escrowId}");
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
            var d       = Deserialize(body);
            var prov    = d.GetValueOrDefault("provider")?.ToString() ?? "0x0";
            var limit   = decimal.Parse(d.GetValueOrDefault("limit_amount")?.ToString() ?? "0");
            var perUnit = decimal.Parse(d.GetValueOrDefault("per_unit")?.ToString() ?? "0");
            var expiry  = long.TryParse(d.GetValueOrDefault("expiry")?.ToString(), out var exp) ? exp : (long?)null;

            var tab = new Tab(id, MockAddress, prov, limit, perUnit, 0m, limit, TabStatus.Open, now, expiry);
            lock (_mock._lock) _mock._tabs[id] = tab;
            return tab;
        }

        private TabCharge HandleTabCharge(string path, object body, string id)
        {
            var tabId      = PathId(path.Replace("/charge", ""));
            var d          = Deserialize(body);
            var amount     = decimal.Parse(d.GetValueOrDefault("amount")?.ToString() ?? "0");
            var cumulative = decimal.Parse(d.GetValueOrDefault("cumulative")?.ToString() ?? "0");
            var callCount  = int.Parse(d.GetValueOrDefault("call_count")?.ToString() ?? "0");
            var provSig    = d.GetValueOrDefault("provider_sig")?.ToString() ?? "0x";

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
                return new TabCharge(tabId, amount, cumulative, callCount, provSig);
            }
        }

        private Tab HandleTabClose(string path, object body, string id, DateTimeOffset now)
        {
            var tabId = PathId(path.Replace("/close", ""));
            lock (_mock._lock)
            {
                if (!_mock._tabs.TryGetValue(tabId, out var tab))
                    throw new RemitError(ErrorCodes.TabNotFound, $"Tab not found: {tabId}");
                var closed = tab with { Status = TabStatus.Settled };
                _mock._tabs[tabId] = closed;
                return closed;
            }
        }

        // ── Stream ───────────────────────────────────────────────────────────

        private Stream HandleCreateStream(object body, string id, DateTimeOffset now)
        {
            var d      = Deserialize(body);
            var payee  = d.GetValueOrDefault("payee")?.ToString() ?? "0x0";
            var rate   = decimal.Parse(d.GetValueOrDefault("rate_per_second")?.ToString() ?? "0");
            var maxTot = decimal.Parse(d.GetValueOrDefault("max_total")?.ToString() ?? "0");

            lock (_mock._lock)
            {
                if (_mock._balance < maxTot)
                    throw new RemitError(ErrorCodes.InsufficientFunds,
                        $"Insufficient funds for stream: balance {_mock._balance:F6}, max_total {maxTot:F6}.");
                _mock._balance -= maxTot;
                var stream = new Stream(id, MockAddress, payee, rate, maxTot, 0m, StreamStatus.Active, now, null);
                _mock._streams[id] = stream;
                return stream;
            }
        }

        private Transaction HandleStreamClose(string path, string id, DateTimeOffset now)
        {
            var streamId = PathId(path.Replace("/close", ""));
            lock (_mock._lock)
            {
                if (!_mock._streams.TryGetValue(streamId, out var stream))
                    throw new RemitError(ErrorCodes.StreamNotFound, $"Stream not found: {streamId}");
                if (stream.Status != StreamStatus.Active)
                    throw new RemitError(ErrorCodes.StreamNotActive, $"Stream {streamId} is not active.");

                _mock._streams[streamId] = stream with { Status = StreamStatus.Ended };
                return new Transaction(id, "0x" + id, MockAddress, stream.Recipient,
                    stream.Deposited, 0m, "stream close", ChainId.BaseSepolia, 1_000_003ul, now);
            }
        }

        // ── Bounty ───────────────────────────────────────────────────────────

        private int _nextSubmissionId = 1;

        private Bounty HandleCreateBounty(object body, string id, DateTimeOffset now)
        {
            var d      = Deserialize(body);
            var amount = decimal.Parse(d.GetValueOrDefault("amount")?.ToString() ?? "0");
            var desc   = d.GetValueOrDefault("task_description")?.ToString() ?? "";
            var dl     = long.TryParse(d.GetValueOrDefault("deadline")?.ToString(), out var dv) ? dv : (long?)null;

            lock (_mock._lock)
            {
                if (_mock._balance < amount)
                    throw new RemitError(ErrorCodes.InsufficientFunds,
                        $"Insufficient funds for bounty: balance {_mock._balance:F6}, amount {amount:F6}.");
                _mock._balance -= amount;
                var bounty = new Bounty(id, MockAddress, amount, desc, BountyStatus.Open, dl, now);
                _mock._bounties[id] = bounty;
                return bounty;
            }
        }

        private BountySubmission HandleBountySubmit(string path, object body, string id)
        {
            var bountyId = PathId(path.Replace("/submit", ""));
            var d        = Deserialize(body);
            var hash     = d.GetValueOrDefault("evidence_hash")?.ToString() ?? "";

            lock (_mock._lock)
            {
                if (!_mock._bounties.TryGetValue(bountyId, out var bounty))
                    throw new RemitError(ErrorCodes.BountyNotFound, $"Bounty not found: {bountyId}");
                if (bounty.Status != BountyStatus.Open)
                    throw new RemitError(ErrorCodes.BountyAlreadyClosed, $"Bounty {bountyId} is not open.");

                var subId = _nextSubmissionId++;
                return new BountySubmission(subId, bountyId, MockAddress, hash);
            }
        }

        private Bounty HandleBountyAward(string path, object body, string id, DateTimeOffset now)
        {
            var bountyId     = PathId(path.Replace("/award", ""));
            var d            = Deserialize(body);

            lock (_mock._lock)
            {
                if (!_mock._bounties.TryGetValue(bountyId, out var bounty))
                    throw new RemitError(ErrorCodes.BountyNotFound, $"Bounty not found: {bountyId}");
                if (bounty.Status != BountyStatus.Open)
                    throw new RemitError(ErrorCodes.BountyAlreadyClosed, $"Bounty {bountyId} is not open.");

                var awarded = bounty with { Status = BountyStatus.Awarded };
                _mock._bounties[bountyId] = awarded;
                return awarded;
            }
        }

        // ── Deposit ──────────────────────────────────────────────────────────

        private Deposit HandleCreateDeposit(object body, string id, DateTimeOffset now)
        {
            var d      = Deserialize(body);
            var prov   = d.GetValueOrDefault("provider")?.ToString() ?? "0x0";
            var amt    = decimal.Parse(d.GetValueOrDefault("amount")?.ToString() ?? "0");
            var expiry = long.TryParse(d.GetValueOrDefault("expiry")?.ToString(), out var exp) ? exp : (long?)null;

            lock (_mock._lock)
            {
                if (_mock._balance < amt)
                    throw new RemitError(ErrorCodes.InsufficientFunds,
                        $"Insufficient funds for deposit: balance {_mock._balance:F6}, amount {amt:F6}.");
                _mock._balance -= amt;
                var deposit = new Deposit(id, MockAddress, prov, amt, DepositStatus.Locked, expiry, now);
                _mock._deposits[id] = deposit;
                return deposit;
            }
        }

        private Transaction HandleDepositReturn(string path, string id, DateTimeOffset now)
        {
            var depositId = PathId(path.Replace("/return", ""));
            lock (_mock._lock)
            {
                if (!_mock._deposits.TryGetValue(depositId, out var deposit))
                    throw new RemitError(ErrorCodes.ServerError, $"Deposit not found: {depositId}");
                _mock._balance += deposit.Amount; // full refund, no fee
                _mock._deposits[depositId] = deposit with { Status = DepositStatus.Returned };
                return new Transaction(id, "0x" + id, deposit.Provider, MockAddress,
                    deposit.Amount, 0m, "deposit return", ChainId.BaseSepolia, 1_000_005ul, now);
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
        public string Sign(byte[] hash)
        {
            // Return a valid 65-byte signature (r:32 + s:32 + v:1)
            var sig = new byte[65];
            Buffer.BlockCopy(hash, 0, sig, 0, Math.Min(hash.Length, 32)); // r = hash
            Buffer.BlockCopy(hash, 0, sig, 32, Math.Min(hash.Length, 32)); // s = hash
            sig[64] = 27; // v
            return "0x" + Convert.ToHexString(sig).ToLowerInvariant();
        }
    }
}
