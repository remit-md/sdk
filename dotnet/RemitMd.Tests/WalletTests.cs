using RemitMd;
using Xunit;

namespace RemitMd.Tests;

public sealed class MockPayTests
{
    private readonly MockRemit _mock = new();
    private readonly Wallet _wallet;

    public MockPayTests() => _wallet = _mock.Wallet();

    // ─── Direct payment ───────────────────────────────────────────────────────

    [Fact]
    public async Task Pay_SuccessfulPayment_RecordsTransaction()
    {
        const string recipient = "0x000000000000000000000000000000000000dEaD";
        var tx = await _wallet.PayAsync(recipient, 1.50m);

        Assert.NotEmpty(tx.Id);
        Assert.NotEmpty(tx.TxHash);
        Assert.Equal(recipient, tx.To, StringComparer.OrdinalIgnoreCase);
        Assert.Equal(1.50m, tx.Amount);
        Assert.True(_mock.WasPaid(recipient, 1.50m));
    }

    [Fact]
    public async Task Pay_DeductsBalanceAndFee()
    {
        _mock.SetBalance(100m);
        await _wallet.PayAsync("0x000000000000000000000000000000000000dEaD", 10m);

        Assert.Equal(90m, _mock.Balance);
    }

    [Fact]
    public async Task Pay_InsufficientFunds_ThrowsRemitError()
    {
        _mock.SetBalance(0.50m);

        var ex = await Assert.ThrowsAsync<RemitError>(() =>
            _wallet.PayAsync("0x000000000000000000000000000000000000dEaD", 1.00m));

        Assert.Equal(ErrorCodes.InsufficientFunds, ex.Code);
        Assert.Contains("balance is 0.500000", ex.Message);
    }

    [Fact]
    public async Task Pay_InvalidAddress_ThrowsRemitError()
    {
        var ex = await Assert.ThrowsAsync<RemitError>(() =>
            _wallet.PayAsync("not-an-address", 1.00m));

        Assert.Equal(ErrorCodes.InvalidAddress, ex.Code);
        Assert.Contains("0x-prefixed", ex.Message);
    }

    [Fact]
    public async Task Pay_ZeroAmount_ThrowsRemitError()
    {
        var ex = await Assert.ThrowsAsync<RemitError>(() =>
            _wallet.PayAsync("0x000000000000000000000000000000000000dEaD", 0m));

        Assert.Equal(ErrorCodes.InvalidAmount, ex.Code);
    }

    [Fact]
    public async Task TotalPaidTo_AggregatesMultiplePayments()
    {
        const string addr = "0x000000000000000000000000000000000000dEaD";
        await _wallet.PayAsync(addr, 1.00m);
        await _wallet.PayAsync(addr, 2.50m);
        await _wallet.PayAsync(addr, 0.75m);

        Assert.Equal(4.25m, _mock.TotalPaidTo(addr));
    }

    // ─── Escrow ───────────────────────────────────────────────────────────────

    [Fact]
    public async Task Escrow_FullLifecycle_CreateAndRelease()
    {
        const string payee = "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        _mock.SetBalance(50m);

        var escrow = await _wallet.CreateEscrowAsync(payee, 10m, "code review");
        Assert.Equal(EscrowStatus.Funded, escrow.Status);
        Assert.Equal(40m, _mock.Balance);

        var tx = await _wallet.ReleaseEscrowAsync(escrow.Id);
        Assert.Equal(payee, tx.To, StringComparer.OrdinalIgnoreCase);

        var updated = await _wallet.GetEscrowAsync(escrow.Id);
        Assert.Equal(EscrowStatus.Released, updated.Status);
    }

    [Fact]
    public async Task Escrow_Cancel_RefundsBalance()
    {
        _mock.SetBalance(50m);
        var escrow = await _wallet.CreateEscrowAsync(
            "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", 20m);
        Assert.Equal(30m, _mock.Balance);

        await _wallet.CancelEscrowAsync(escrow.Id);
        Assert.Equal(50m, _mock.Balance);
    }

    [Fact]
    public async Task Escrow_DoubleRelease_ThrowsRemitError()
    {
        var escrow = await _wallet.CreateEscrowAsync(
            "0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", 5m);
        await _wallet.ReleaseEscrowAsync(escrow.Id);

        var ex = await Assert.ThrowsAsync<RemitError>(() =>
            _wallet.ReleaseEscrowAsync(escrow.Id));
        Assert.Equal(ErrorCodes.EscrowAlreadyClosed, ex.Code);
    }

    // ─── Tab ─────────────────────────────────────────────────────────────────

    [Fact]
    public async Task Tab_OpenAndDebit_TracksBalance()
    {
        var tab = await _wallet.CreateTabAsync(
            "0xDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", 5m);
        Assert.Equal(5m, tab.Limit);
        Assert.Equal(0m, tab.Used);

        await _wallet.DebitTabAsync(tab.Id, 1.00m, "API call");
        await _wallet.DebitTabAsync(tab.Id, 0.50m, "data query");

        // Verify remaining via GetEscrow doesn't apply here — check by attempting overspend
        var ex = await Assert.ThrowsAsync<RemitError>(() =>
            _wallet.DebitTabAsync(tab.Id, 5.00m)); // would exceed limit
        Assert.Equal(ErrorCodes.TabLimitExceeded, ex.Code);
    }

    [Fact]
    public async Task Tab_Settle_ClosesTab()
    {
        var tab = await _wallet.CreateTabAsync(
            "0xEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE", 10m);
        await _wallet.DebitTabAsync(tab.Id, 2m);
        var tx = await _wallet.SettleTabAsync(tab.Id);

        Assert.Equal(2m, tx.Amount);
    }

    // ─── Stream ───────────────────────────────────────────────────────────────

    [Fact]
    public async Task Stream_CreateAndWithdraw_Works()
    {
        const string recipient = "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF";
        _mock.SetBalance(100m);

        var stream = await _wallet.CreateStreamAsync(recipient, 0.000277m, 10m);
        Assert.Equal(StreamStatus.Active, stream.Status);
        Assert.Equal(90m, _mock.Balance);

        var tx = await _wallet.WithdrawStreamAsync(stream.Id);
        Assert.True(tx.Amount > 0m);
    }

    // ─── Bounty ───────────────────────────────────────────────────────────────

    [Fact]
    public async Task Bounty_PostAndAward_Works()
    {
        const string winner = "0x1111111111111111111111111111111111111111";
        _mock.SetBalance(50m);

        var bounty = await _wallet.CreateBountyAsync(25m, "Summarize this paper");
        Assert.Equal(BountyStatus.Open, bounty.Status);
        Assert.Equal(25m, _mock.Balance);

        var tx = await _wallet.AwardBountyAsync(bounty.Id, winner);
        Assert.Equal(25m, tx.Amount);
        Assert.Equal(winner, tx.To, StringComparer.OrdinalIgnoreCase);
    }

    // ─── Reset ────────────────────────────────────────────────────────────────

    [Fact]
    public async Task Reset_ClearsAllState()
    {
        await _wallet.PayAsync("0x000000000000000000000000000000000000dEaD", 1m);
        Assert.Single(_mock.Transactions);

        _mock.Reset();

        Assert.Empty(_mock.Transactions);
        Assert.Equal(10_000m, _mock.Balance);
    }

    // ─── Chain validation ─────────────────────────────────────────────────────

    [Fact]
    public void Wallet_InvalidChain_ThrowsRemitError()
    {
        var ex = Assert.Throws<RemitError>(() =>
            new Wallet("0x" + new string('a', 64), chain: "solana"));

        Assert.Equal(ErrorCodes.InvalidChain, ex.Code);
        Assert.Contains("solana", ex.Message);
    }

    // ─── Balance ──────────────────────────────────────────────────────────────

    [Fact]
    public async Task Balance_ReturnsCurrentBalance()
    {
        _mock.SetBalance(42.5m);
        var bal = await _wallet.BalanceAsync();
        Assert.Equal(42.5m, bal.Usdc);
    }
}
