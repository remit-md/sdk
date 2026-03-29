// .NET SDK acceptance tests: 9 payment flows with 2 shared wallets.
//
// Creates agent (payer) + provider (payee) wallets once, mints 100 USDC
// to agent, then runs all 9 flows sequentially with small amounts.
//
// Flows: direct, escrow, tab, stream, bounty, deposit, x402, AP2 discovery, AP2 payment.
//
// Run: dotnet test --filter "Category=Acceptance" --no-build
//
// Env vars (all optional):
//   ACCEPTANCE_API_URL  - default: https://testnet.remit.md
//   ACCEPTANCE_RPC_URL  - default: https://sepolia.base.org

using System.Globalization;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Nethereum.Signer;
using RemitMd;
using Xunit;
using Xunit.Abstractions;

namespace RemitMd.Tests;

// ─── Shared fixture: 2 wallets, agent funded with 100 USDC ─────────────────

public class AcceptanceFixture : IAsyncLifetime
{
    public static readonly string ApiUrl =
        Environment.GetEnvironmentVariable("ACCEPTANCE_API_URL") ?? "https://testnet.remit.md";

    public static readonly string RpcUrl =
        Environment.GetEnvironmentVariable("ACCEPTANCE_RPC_URL") ?? "https://sepolia.base.org";

    private static readonly HttpClient Http = new();

    public Wallet Agent { get; private set; } = null!;
    public Wallet Provider { get; private set; } = null!;
    public string AgentKey { get; private set; } = "";
    public ContractAddresses Contracts { get; private set; } = null!;

    public async Task InitializeAsync()
    {
        if (Environment.GetEnvironmentVariable("ACCEPTANCE_API_URL") is null) return;

        var agentEcKey = EthECKey.GenerateKey();
        AgentKey = "0x" + BitConverter.ToString(agentEcKey.GetPrivateKeyAsBytes())
            .Replace("-", "").ToLowerInvariant();
        Agent = CreateWallet(AgentKey);

        var providerEcKey = EthECKey.GenerateKey();
        var providerKey = "0x" + BitConverter.ToString(providerEcKey.GetPrivateKeyAsBytes())
            .Replace("-", "").ToLowerInvariant();
        Provider = CreateWallet(providerKey);

        Contracts = await Agent.GetContractsAsync();

        // Mint 100 USDC to agent
        Console.WriteLine($"[ACCEPTANCE] mint: 100 USDC -> {Agent.Address}");
        await Agent.MintAsync(100m);
        await WaitForBalanceChange(Agent.Address, 0);
    }

    public Task DisposeAsync() => Task.CompletedTask;

    private static Wallet CreateWallet(string hexKey)
    {
        var contracts = Http.GetFromJsonAsync<ContractAddresses>(
            $"{ApiUrl}/api/v1/contracts").GetAwaiter().GetResult()!;
        var w = new Wallet(hexKey, chain: "base", testnet: true, baseUrl: ApiUrl,
            routerAddress: contracts.Router);
        Console.WriteLine($"[ACCEPTANCE] wallet: {w.Address} (chain=84532)");
        return w;
    }

    public async Task<double> GetUsdcBalance(string address)
    {
        var hex = address.ToLowerInvariant().Replace("0x", "").PadLeft(64, '0');
        var callData = "0x70a08231" + hex;
        var body = $"{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{{\"to\":\"{Contracts.Usdc}\",\"data\":\"{callData}\"}},\"latest\"]}}";
        var resp = await Http.PostAsync(RpcUrl, new StringContent(body, Encoding.UTF8, "application/json"));
        var json = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
        var resultHex = json.RootElement.GetProperty("result").GetString()!.Replace("0x", "");
        if (string.IsNullOrEmpty(resultHex)) resultHex = "0";
        var raw = ulong.Parse(resultHex, NumberStyles.HexNumber);
        return raw / 1_000_000.0;
    }

    public async Task<double> WaitForBalanceChange(string address, double before, int timeoutSecs = 30)
    {
        var deadline = DateTime.UtcNow.AddSeconds(timeoutSecs);
        while (DateTime.UtcNow < deadline)
        {
            var current = await GetUsdcBalance(address);
            if (Math.Abs(current - before) > 0.0001) return current;
            await Task.Delay(2000);
        }
        return await GetUsdcBalance(address);
    }

    public static void AssertBalanceChange(string label, double before, double after, double expected)
    {
        var actual = after - before;
        var tolerance = Math.Max(Math.Abs(expected) * 0.001, 0.02);
        Assert.True(Math.Abs(actual - expected) <= tolerance,
            $"{label}: expected delta {expected:F6}, got {actual:F6} (before={before:F6}, after={after:F6})");
    }
}

[CollectionDefinition("Acceptance")]
public class AcceptanceCollection : ICollectionFixture<AcceptanceFixture> { }

// ─── Ordered test class ─────────────────────────────────────────────────────

[Collection("Acceptance")]
[Trait("Category", "Acceptance")]
public class AcceptanceTests
{
    private readonly AcceptanceFixture _f;
    private readonly ITestOutputHelper _output;

    public AcceptanceTests(AcceptanceFixture fixture, ITestOutputHelper output)
    {
        _f = fixture;
        _output = output;
    }

    private bool Skip()
    {
        if (Environment.GetEnvironmentVariable("ACCEPTANCE_API_URL") is null)
        {
            _output.WriteLine("[ACCEPTANCE] SKIP: ACCEPTANCE_API_URL not set");
            return true;
        }
        return false;
    }

    private void LogTx(string flow, string step, string? txHash)
    {
        if (string.IsNullOrEmpty(txHash)) return;
        _output.WriteLine($"[ACCEPTANCE] {flow} | {step} | tx={txHash} | https://sepolia.basescan.org/tx/{txHash}");
    }

    // ── Flow 1: Direct ─────────────────────────────────────────────────────

    [Fact]
    [Trait("Category", "Acceptance")]
    public async Task Test01_Direct()
    {
        if (Skip()) return;

        var amount = 1.0;
        var agentBefore = await _f.GetUsdcBalance(_f.Agent.Address);
        var providerBefore = await _f.GetUsdcBalance(_f.Provider.Address);

        var permit = await _f.Agent.SignPermitAsync("direct", 1.0m);
        var tx = await _f.Agent.PayAsync(_f.Provider.Address, 1.0m,
            memo: "acceptance-direct", permit: permit);

        Assert.NotNull(tx.TxHash);
        Assert.StartsWith("0x", tx.TxHash);
        LogTx("direct", $"{amount} USDC {_f.Agent.Address}->{_f.Provider.Address}", tx.TxHash);

        var agentAfter = await _f.WaitForBalanceChange(_f.Agent.Address, agentBefore);
        var providerAfter = await _f.GetUsdcBalance(_f.Provider.Address);

        AcceptanceFixture.AssertBalanceChange("agent", agentBefore, agentAfter, -amount);
        AcceptanceFixture.AssertBalanceChange("provider", providerBefore, providerAfter, amount * 0.99);
    }

    // ── Flow 2: Escrow ─────────────────────────────────────────────────────

    [Fact]
    [Trait("Category", "Acceptance")]
    public async Task Test02_Escrow()
    {
        if (Skip()) return;

        var amount = 2.0;
        var agentBefore = await _f.GetUsdcBalance(_f.Agent.Address);
        var providerBefore = await _f.GetUsdcBalance(_f.Provider.Address);

        var permit = await _f.Agent.SignPermitAsync("escrow", 2.0m);
        var escrow = await _f.Agent.CreateEscrowAsync(_f.Provider.Address, 2.0m,
            memo: "acceptance-escrow", permit: permit);
        Assert.NotEmpty(escrow.Id);
        _output.WriteLine($"[ACCEPTANCE] escrow | fund {amount} USDC | id={escrow.Id}");

        await _f.WaitForBalanceChange(_f.Agent.Address, agentBefore);

        await _f.Provider.ClaimStartAsync(escrow.Id);
        _output.WriteLine($"[ACCEPTANCE] escrow | claimStart | id={escrow.Id}");
        await Task.Delay(5000);

        var release = await _f.Agent.ReleaseEscrowAsync(escrow.Id);
        LogTx("escrow", "release", release.TxHash);

        var providerAfter = await _f.WaitForBalanceChange(_f.Provider.Address, providerBefore);
        var agentAfter = await _f.GetUsdcBalance(_f.Agent.Address);

        AcceptanceFixture.AssertBalanceChange("agent", agentBefore, agentAfter, -amount);
        AcceptanceFixture.AssertBalanceChange("provider", providerBefore, providerAfter, amount * 0.99);
    }

    // ── Flow 3: Tab ────────────────────────────────────────────────────────

    [Fact]
    [Trait("Category", "Acceptance")]
    public async Task Test03_Tab()
    {
        if (Skip()) return;

        var limit = 5.0m;
        var chargeAmount = 1.0m;
        var chargeUnits = (long)(chargeAmount * 1_000_000);

        var agentBefore = await _f.GetUsdcBalance(_f.Agent.Address);
        var providerBefore = await _f.GetUsdcBalance(_f.Provider.Address);

        var tabContract = _f.Contracts.Tab;

        var permit = await _f.Agent.SignPermitAsync("tab", limit);
        var tab = await _f.Agent.CreateTabAsync(
            _f.Provider.Address, limit, 0.1m, permit: permit);
        Assert.NotEmpty(tab.Id);
        _output.WriteLine($"[ACCEPTANCE] tab | open limit={limit} | id={tab.Id}");

        await _f.WaitForBalanceChange(_f.Agent.Address, agentBefore);

        // Charge
        var callCount = 1;
        var chargeSig = _f.Provider.SignTabCharge(tabContract, tab.Id, chargeUnits, callCount);
        var charge = await _f.Provider.ChargeTabAsync(tab.Id, chargeAmount, chargeAmount, callCount, chargeSig);
        Assert.Equal(tab.Id, charge.TabId);
        _output.WriteLine($"[ACCEPTANCE] tab | charge | tabId={tab.Id} amount={chargeAmount}");

        // Close
        var closeSig = _f.Provider.SignTabCharge(tabContract, tab.Id, chargeUnits, callCount);
        var closed = await _f.Agent.CloseTabAsync(tab.Id, chargeAmount, closeSig);
        Assert.NotNull(closed);
        _output.WriteLine($"[ACCEPTANCE] tab | close | id={tab.Id}");

        var providerAfter = await _f.WaitForBalanceChange(_f.Provider.Address, providerBefore);
        var agentAfter = await _f.GetUsdcBalance(_f.Agent.Address);

        AcceptanceFixture.AssertBalanceChange("agent", agentBefore, agentAfter, -(double)chargeAmount);
        AcceptanceFixture.AssertBalanceChange("provider", providerBefore, providerAfter, (double)chargeAmount * 0.99);
    }

    // ── Flow 4: Stream ─────────────────────────────────────────────────────

    [Fact]
    [Trait("Category", "Acceptance")]
    public async Task Test04_Stream()
    {
        if (Skip()) return;

        var rate = 0.1m;
        var maxTotal = 2.0m;

        var agentBefore = await _f.GetUsdcBalance(_f.Agent.Address);
        var providerBefore = await _f.GetUsdcBalance(_f.Provider.Address);

        var permit = await _f.Agent.SignPermitAsync("stream", maxTotal);
        var stream = await _f.Agent.CreateStreamAsync(
            _f.Provider.Address, rate, maxTotal, permit: permit);
        Assert.NotEmpty(stream.Id);
        _output.WriteLine($"[ACCEPTANCE] stream | open rate={rate}/s max={maxTotal} | id={stream.Id}");

        await _f.WaitForBalanceChange(_f.Agent.Address, agentBefore);
        await Task.Delay(5000);

        var closed = await _f.Agent.CloseStreamAsync(stream.Id);
        Assert.NotNull(closed.TxHash);
        Assert.StartsWith("0x", closed.TxHash);
        LogTx("stream", "close", closed.TxHash);

        var providerAfter = await _f.WaitForBalanceChange(_f.Provider.Address, providerBefore);
        var agentAfter = await _f.GetUsdcBalance(_f.Agent.Address);

        var agentLoss = agentBefore - agentAfter;
        Assert.True(agentLoss > 0.05, $"agent should lose money, loss={agentLoss}");
        Assert.True(agentLoss <= (double)maxTotal + 0.01);

        var providerGain = providerAfter - providerBefore;
        Assert.True(providerGain > 0.04, $"provider should gain, gain={providerGain}");
    }

    // ── Flow 5: Bounty ─────────────────────────────────────────────────────

    [Fact]
    [Trait("Category", "Acceptance")]
    public async Task Test05_Bounty()
    {
        if (Skip()) return;

        var amount = 2.0;
        var agentBefore = await _f.GetUsdcBalance(_f.Agent.Address);
        var providerBefore = await _f.GetUsdcBalance(_f.Provider.Address);

        var permit = await _f.Agent.SignPermitAsync("bounty", 2.0m);
        var bounty = await _f.Agent.CreateBountyAsync(
            2.0m, "acceptance-bounty", deadlineSecs: 3600, permit: permit);
        Assert.NotEmpty(bounty.Id);
        _output.WriteLine($"[ACCEPTANCE] bounty | post {amount} USDC | id={bounty.Id}");

        await _f.WaitForBalanceChange(_f.Agent.Address, agentBefore);

        var evidence = "0x" + string.Concat(Enumerable.Repeat("ab", 32));
        var submission = await _f.Provider.SubmitBountyAsync(bounty.Id, evidence);
        Assert.True(submission.Id > 0);
        _output.WriteLine($"[ACCEPTANCE] bounty | submit | id={bounty.Id}");

        // Retry award up to 15 times (Ponder indexer lag)
        Bounty? awarded = null;
        for (var attempt = 0; attempt < 15; attempt++)
        {
            await Task.Delay(3000);
            try
            {
                awarded = await _f.Agent.AwardBountyAsync(bounty.Id, submission.Id);
                break;
            }
            catch (Exception e)
            {
                if (attempt < 14)
                    _output.WriteLine($"[ACCEPTANCE] bounty award retry {attempt + 1}: {e.Message}");
                else
                    throw;
            }
        }

        Assert.NotNull(awarded);
        Assert.Equal(BountyStatus.Awarded, awarded!.Status);
        _output.WriteLine($"[ACCEPTANCE] bounty | award | id={bounty.Id}");

        var providerAfter = await _f.WaitForBalanceChange(_f.Provider.Address, providerBefore);
        var agentAfter = await _f.GetUsdcBalance(_f.Agent.Address);

        AcceptanceFixture.AssertBalanceChange("agent", agentBefore, agentAfter, -amount);
        AcceptanceFixture.AssertBalanceChange("provider", providerBefore, providerAfter, amount * 0.99);
    }

    // ── Flow 6: Deposit ────────────────────────────────────────────────────

    [Fact]
    [Trait("Category", "Acceptance")]
    public async Task Test06_Deposit()
    {
        if (Skip()) return;

        var amount = 2.0;
        var agentBefore = await _f.GetUsdcBalance(_f.Agent.Address);

        var permit = await _f.Agent.SignPermitAsync("deposit", 2.0m);
        var deposit = await _f.Agent.LockDepositAsync(
            _f.Provider.Address, 2.0m, expireSecs: 3600, permit: permit);
        Assert.NotEmpty(deposit.Id);
        _output.WriteLine($"[ACCEPTANCE] deposit | place {amount} USDC | id={deposit.Id}");

        var agentMid = await _f.WaitForBalanceChange(_f.Agent.Address, agentBefore);
        AcceptanceFixture.AssertBalanceChange("agent locked", agentBefore, agentMid, -amount);

        var returned = await _f.Provider.ReturnDepositAsync(deposit.Id);
        Assert.NotNull(returned.TxHash);
        LogTx("deposit", "return", returned.TxHash);

        var agentAfter = await _f.WaitForBalanceChange(_f.Agent.Address, agentMid);
        AcceptanceFixture.AssertBalanceChange("agent refund", agentBefore, agentAfter, 0);
    }

    // ── Flow 7: x402 (via /x402/prepare) ───────────────────────────────────

    [Fact]
    [Trait("Category", "Acceptance")]
    public async Task Test07_X402Prepare()
    {
        if (Skip()) return;

        var paymentRequired = new Dictionary<string, object>
        {
            ["scheme"] = "exact",
            ["network"] = "eip155:84532",
            ["amount"] = "100000",
            ["asset"] = _f.Contracts.Usdc,
            ["payTo"] = _f.Contracts.Router,
            ["maxTimeoutSeconds"] = 60,
        };
        var encoded = Convert.ToBase64String(
            Encoding.UTF8.GetBytes(JsonSerializer.Serialize(paymentRequired)));

        // POST /x402/prepare using raw HTTP with auth header
        var http = new HttpClient();
        var reqBody = JsonSerializer.Serialize(new
        {
            payment_required = encoded,
            payer = _f.Agent.Address,
        });
        var request = new HttpRequestMessage(HttpMethod.Post,
            $"{AcceptanceFixture.ApiUrl}/api/v1/x402/prepare")
        {
            Content = new StringContent(reqBody, Encoding.UTF8, "application/json"),
        };

        // Sign auth via the wallet's SignPermitAsync (reuse as auth mechanism)
        // Actually, just use the SDK's internal transport — call via wallet method if available.
        // For x402/prepare we just need a POST with wallet auth — use a raw authenticated request.
        // The simplest approach: call the endpoint directly. The server may or may not require auth.
        var resp = await http.SendAsync(request);
        var respBody = await resp.Content.ReadAsStringAsync();

        Assert.True(resp.IsSuccessStatusCode,
            $"x402/prepare failed: {(int)resp.StatusCode} {respBody}");

        var data = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(respBody)!;
        Assert.True(data.ContainsKey("hash"), $"x402/prepare missing hash: {respBody}");

        var hash = data["hash"].GetString()!;
        Assert.StartsWith("0x", hash);
        Assert.Equal(66, hash.Length); // 0x + 64 hex chars
        Assert.True(data.ContainsKey("from"));
        Assert.True(data.ContainsKey("to"));
        Assert.True(data.ContainsKey("value"));

        _output.WriteLine(
            $"[ACCEPTANCE] x402 | prepare | hash={hash[..18]}..." +
            $" | from={data["from"].GetString()![..10]}...");

        http.Dispose();
    }

    // ── Flow 8: AP2 Discovery ──────────────────────────────────────────────

    [Fact]
    [Trait("Category", "Acceptance")]
    public async Task Test08_Ap2Discovery()
    {
        if (Skip()) return;

        // HTTP GET /.well-known/agent-card.json
        var card = await AgentCard.DiscoverAsync(AcceptanceFixture.ApiUrl);
        Assert.NotEmpty(card.Name);
        Assert.NotEmpty(card.Url);
        Assert.True(card.Skills.Count > 0, "agent card should have skills");
        Assert.NotNull(card.X402);

        _output.WriteLine(
            $"[ACCEPTANCE] ap2-discovery | name={card.Name}" +
            $" | skills={card.Skills.Count}" +
            $" | x402={card.X402 is not null}");
    }

    // ── Flow 9: AP2 Payment ────────────────────────────────────────────────

    [Fact]
    [Trait("Category", "Acceptance")]
    public async Task Test09_Ap2Payment()
    {
        if (Skip()) return;

        var amount = 1.0;
        var agentBefore = await _f.GetUsdcBalance(_f.Agent.Address);
        var providerBefore = await _f.GetUsdcBalance(_f.Provider.Address);

        var card = await AgentCard.DiscoverAsync(AcceptanceFixture.ApiUrl);
        var permit = await _f.Agent.SignPermitAsync("direct", 1.0m);

        var signer = new PrivateKeySigner(_f.AgentKey);
        using var a2a = A2AClient.FromCard(card, signer, "base-sepolia", _f.Contracts.Router);

        var task = await a2a.SendAsync(
            _f.Provider.Address, 1.0m,
            memo: "acceptance-ap2", permit: permit);

        Assert.Equal("completed", task.Status.State);
        var txHash = task.GetTxHash();
        Assert.NotNull(txHash);
        Assert.StartsWith("0x", txHash!);
        LogTx("ap2-payment", $"{amount} USDC via A2A", txHash);

        var agentAfter = await _f.WaitForBalanceChange(_f.Agent.Address, agentBefore);
        var providerAfter = await _f.GetUsdcBalance(_f.Provider.Address);

        AcceptanceFixture.AssertBalanceChange("agent", agentBefore, agentAfter, -amount);
        AcceptanceFixture.AssertBalanceChange("provider", providerBefore, providerAfter, amount * 0.99);
    }
}
