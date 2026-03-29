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
                .Sum(t => t.Amount ?? 0m);
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
                var p when p.StartsWith("/api/v1/status/") => (object)new WalletStatus(
                    MockAddress, _mock._balance.ToString("F6"), "0.000000", "new", 100,
                    _mock._escrows.Count, _mock._tabs.Count, _mock._streams.Count, 0),

                "/api/v1/invoices" =>
                    new TransactionList(_mock._transactions.ToList(), _mock._transactions.Count, 1, 20, false),

                var p when p.StartsWith("/api/v1/reputation/") => new Reputation(
                    MockAddress, 0m, "standard",
                    _mock._transactions.Sum(t => t.Amount ?? 0m),
                    _mock._transactions.Count, DateTimeOffset.UtcNow),

                var p when p.StartsWith("/api/v1/escrows/") =>
                    _mock._escrows.TryGetValue(PathId(p), out var e)
                        ? (object)e
                        : throw new RemitError(ErrorCodes.EscrowNotFound, $"Escrow not found: {PathId(p)}"),

                "/api/v1/contracts" => new ContractAddresses(
                    84532,
                    "0x2d846325766921935f37d5b4478196d3ef93707c",
                    "0x3120f396ff6a9afc5a9d92e28796082f1429e024",
                    "0x47de7cdd757e3765d36c083dab59b2c5a9d249f2",
                    "0x9415f510d8c6199e0f66bde927d7d88de391f5e8",
                    "0x20d413e0eac0f5da3c8630667fd16a94fcd7231a",
                    "0xb3868471c3034280cce3a56dd37c6154c3bb0b32",
                    "0x7e0ae37df62e93c1c16a5661a7998bd174331554",
                    "0xcce1b8cee59f860578bed3c05fe2a80eea04aafb",
                    "0xf5ba0baa124885eb88ad225e81a60864d5e43074",
                    "0x4b88c779c970314216b97ca94cb6d380db57ce91"),

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
                "/api/v1/permits/prepare"              => HandlePermitsPrepare(body),
                "/api/v1/payments/direct"              => HandlePay(body, id, now),

                "/api/v1/invoices"                     => HandleCreateInvoice(body),
                "/api/v1/escrows"                      => HandleCreateEscrow(body, now),
                var p when p.EndsWith("/claim-start")  => HandleClaimStart(p),
                var p when p.EndsWith("/release")      => HandleEscrowAction(p, "released"),
                var p when p.EndsWith("/cancel")       => HandleEscrowAction(p, "cancelled"),

                "/api/v1/tabs"                         => HandleCreateTab(body, id, now),
                var p when p.StartsWith("/api/v1/tabs/") && p.EndsWith("/charge")
                                                       => HandleTabCharge(p, body, id),
                var p when p.StartsWith("/api/v1/tabs/") && p.EndsWith("/close")
                                                       => HandleTabClose(p, body, id, now),

                "/api/v1/streams"                      => HandleCreateStream(body, id, now),
                var p when p.StartsWith("/api/v1/streams/") && p.EndsWith("/close")
                                                       => HandleStreamClose(p, id, now),

                "/api/v1/bounties"                     => HandleCreateBounty(body, id, now),
                var p when p.StartsWith("/api/v1/bounties/") && p.EndsWith("/submit")
                                                       => HandleBountySubmit(p, body, id),
                var p when p.StartsWith("/api/v1/bounties/") && p.EndsWith("/award")
                                                       => HandleBountyAward(p, body, id, now),
                var p when p.StartsWith("/api/v1/bounties/") && p.EndsWith("/reclaim")
                                                       => HandleBountyReclaim(p, id, now),

                "/api/v1/deposits"                     => HandleCreateDeposit(body, id, now),
                var p when p.StartsWith("/api/v1/deposits/") && p.EndsWith("/return")
                                                       => HandleDepositReturn(p, id, now),
                var p when p.StartsWith("/api/v1/deposits/") && p.EndsWith("/forfeit")
                                                       => HandleDepositForfeit(p, id, now),

                _ => throw new RemitError(ErrorCodes.ServerError, $"Mock: unhandled POST {path}"),
            };

            return Task.FromResult(Reserialize<T>(result));
        }

        public Task DeleteAsync(string path, CancellationToken ct)
        {
            // Mock delete - no-op
            return Task.CompletedTask;
        }

        public Task<T> PatchAsync<T>(string path, object body, CancellationToken ct)
        {
            object result = path switch
            {
                var p when p.StartsWith("/api/v1/webhooks/") =>
                    (object)new Webhook("mock-wh", MockAddress, "https://example.com/webhook",
                        new[] { "payment.sent" }, new[] { "mock" }, true, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow),
                "/api/v1/wallet/settings" =>
                    (object)new WalletSettings(MockAddress, "test-agent"),
                _ => throw new RemitError(ErrorCodes.ServerError, $"Mock: unhandled PATCH {path}"),
            };
            return Task.FromResult(Reserialize<T>(result));
        }

        // ── Permit ───────────────────────────────────────────────────────────

        private object HandlePermitsPrepare(object body)
        {
            // Return a deterministic mock hash and permit fields.
            return new Dictionary<string, object>
            {
                ["hash"] = "0x" + new string('a', 64),
                ["value"] = 1000000L,
                ["deadline"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600,
            };
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

                if (escrow.Status == EscrowStatus.Completed || escrow.Status == EscrowStatus.Cancelled)
                    throw new RemitError(ErrorCodes.EscrowAlreadyClosed,
                        $"Escrow {escrowId} is already {escrow.Status.ToString().ToLower()}.");

                var newStatus = action == "released" ? EscrowStatus.Completed : EscrowStatus.Cancelled;
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
            var expiry  = d.GetValueOrDefault("expiry")?.ToString();

            var tab = new Tab(id, MockAddress, prov, limit, perUnit, 0m, TabStatus.Open, now, expiry);
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
                    throw new RemitError(ErrorCodes.TabDepleted, $"Tab {tabId} is not open.");
                var remaining = tab.Limit - tab.Spent;
                if (remaining < amount)
                    throw new RemitError(ErrorCodes.TabLimitExceeded,
                        $"Tab limit exceeded: remaining {remaining:F6}, requested {amount:F6}.");

                _mock._tabs[tabId] = tab with { Spent = tab.Spent + amount };
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
                var closed = tab with { Status = TabStatus.Closed };
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
                var stream = new Stream(id, MockAddress, payee, rate, 0, maxTot, 0m, StreamStatus.Active, now, null);
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

                _mock._streams[streamId] = stream with { Status = StreamStatus.Closed };
                return new Transaction(id, "0x" + id, MockAddress, stream.Payee,
                    stream.MaxTotal ?? 0m, 0m, "stream close", ChainId.BaseSepolia, 1_000_003ul, now);
            }
        }

        // ── Bounty ───────────────────────────────────────────────────────────

        private int _nextSubmissionId = 1;

        private Bounty HandleCreateBounty(object body, string id, DateTimeOffset now)
        {
            var d      = Deserialize(body);
            var amount = decimal.Parse(d.GetValueOrDefault("amount")?.ToString() ?? "0");
            var desc   = d.GetValueOrDefault("task_description")?.ToString() ?? "";
            var dl     = d.GetValueOrDefault("deadline")?.ToString();

            lock (_mock._lock)
            {
                if (_mock._balance < amount)
                    throw new RemitError(ErrorCodes.InsufficientFunds,
                        $"Insufficient funds for bounty: balance {_mock._balance:F6}, amount {amount:F6}.");
                _mock._balance -= amount;
                var bounty = new Bounty(id, MockAddress, amount, desc, BountyStatus.Open, "poster", 10, null, dl, now);
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
            var expiry = d.GetValueOrDefault("expiry")?.ToString();

            lock (_mock._lock)
            {
                if (_mock._balance < amt)
                    throw new RemitError(ErrorCodes.InsufficientFunds,
                        $"Insufficient funds for deposit: balance {_mock._balance:F6}, amount {amt:F6}.");
                _mock._balance -= amt;
                var deposit = new Deposit(id, MockAddress, prov, amt, DepositStatus.Locked, expiry?.ToString(), now);
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
                return new Transaction(id, "0x" + id, deposit.Payee, MockAddress,
                    deposit.Amount, 0m, "deposit return", ChainId.BaseSepolia, 1_000_005ul, now);
            }
        }

        private Transaction HandleBountyReclaim(string path, string id, DateTimeOffset now)
        {
            var bountyId = PathId(path.Replace("/reclaim", ""));
            lock (_mock._lock)
            {
                if (!_mock._bounties.TryGetValue(bountyId, out var bounty))
                    throw new RemitError(ErrorCodes.BountyNotFound, $"Bounty not found: {bountyId}");
                if (bounty.Status != BountyStatus.Open)
                    throw new RemitError(ErrorCodes.BountyAlreadyClosed, $"Bounty {bountyId} is not open.");
                _mock._balance += bounty.Amount;
                _mock._bounties[bountyId] = bounty with { Status = BountyStatus.Cancelled };
                return new Transaction(id, "0x" + id, MockAddress, MockAddress,
                    bounty.Amount, 0m, "bounty reclaim", ChainId.BaseSepolia, 1_000_006ul, now);
            }
        }

        private Transaction HandleDepositForfeit(string path, string id, DateTimeOffset now)
        {
            var depositId = PathId(path.Replace("/forfeit", ""));
            lock (_mock._lock)
            {
                if (!_mock._deposits.TryGetValue(depositId, out var deposit))
                    throw new RemitError(ErrorCodes.ServerError, $"Deposit not found: {depositId}");
                _mock._deposits[depositId] = deposit with { Status = DepositStatus.Forfeited };
                return new Transaction(id, "0x" + id, MockAddress, deposit.Payee,
                    deposit.Amount, 0m, "deposit forfeit", ChainId.BaseSepolia, 1_000_007ul, now);
            }
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
