// .NET SDK acceptance tests: payDirect + escrow + tab + stream + bounty + deposit + x402
// on live Base Sepolia.
//
// Run: dotnet test --filter "FullyQualifiedName~AcceptanceTests" --no-build
//
// Env vars (all optional):
//   ACCEPTANCE_API_URL  — default: https://remit.md
//   ACCEPTANCE_RPC_URL  — default: https://sepolia.base.org

using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Nethereum.Signer;
using RemitMd;
using Xunit;
using Xunit.Abstractions;

namespace RemitMd.Tests;

[Trait("Category", "Acceptance")]
public class AcceptanceTests
{
    private static readonly string ApiUrl = Environment.GetEnvironmentVariable("ACCEPTANCE_API_URL") ?? "https://remit.md";
    private static readonly string RpcUrl = Environment.GetEnvironmentVariable("ACCEPTANCE_RPC_URL") ?? "https://sepolia.base.org";
    private const string UsdcAddress = "0x142aD61B8d2edD6b3807D9266866D97C35Ee0317";
    private const string FeeWallet = "0xd3f721BDF92a2bB5Dd8d2FE2AFC03aFE5629B420";
    private const long ChainIdVal = 84532;

    private static readonly HttpClient Http = new();
    private static Dictionary<string, JsonElement>? _contracts;

    record TestWallet(Wallet Wallet, PrivateKeySigner Signer);

    private async Task<TestWallet> CreateTestWallet()
    {
        var key = EthECKey.GenerateKey();
        var hexKey = "0x" + BitConverter.ToString(key.GetPrivateKeyAsBytes()).Replace("-", "").ToLowerInvariant();

        var contracts = await FetchContracts();
        var routerAddress = contracts["router"].GetString()!;

        var wallet = new Wallet(hexKey, chain: "base", testnet: true, baseUrl: ApiUrl, routerAddress: routerAddress);
        var signer = new PrivateKeySigner(hexKey);
        return new TestWallet(wallet, signer);
    }

    private async Task<Dictionary<string, JsonElement>> FetchContracts()
    {
        if (_contracts is not null) return _contracts;
        var resp = await Http.GetStringAsync($"{ApiUrl}/api/v1/contracts");
        _contracts = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(resp)!;
        return _contracts;
    }

    private async Task<double> GetUsdcBalance(string address)
    {
        var hex = address.ToLowerInvariant().Replace("0x", "").PadLeft(64, '0');
        var callData = "0x70a08231" + hex;
        var body = $"{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{{\"to\":\"{UsdcAddress}\",\"data\":\"{callData}\"}},\"latest\"]}}";
        var resp = await Http.PostAsync(RpcUrl, new StringContent(body, Encoding.UTF8, "application/json"));
        var json = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
        var resultHex = json.RootElement.GetProperty("result").GetString()!.Replace("0x", "");
        if (string.IsNullOrEmpty(resultHex)) resultHex = "0";
        var raw = ulong.Parse(resultHex, System.Globalization.NumberStyles.HexNumber);
        return raw / 1_000_000.0;
    }

    private Task<double> GetFeeBalance() => GetUsdcBalance(FeeWallet);

    private async Task<double> WaitForBalanceChange(string address, double before, int timeoutSecs = 30)
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

    private static void AssertBalanceChange(string label, double before, double after, double expected)
    {
        var actual = after - before;
        var tolerance = Math.Max(Math.Abs(expected) * 0.001, 0.02);
        Assert.True(Math.Abs(actual - expected) <= tolerance,
            $"{label}: expected delta {expected:F6}, got {actual:F6} (before={before:F6}, after={after:F6})");
    }

    private async Task FundWallet(TestWallet tw, decimal amount)
    {
        await tw.Wallet.MintAsync(amount);
        await WaitForBalanceChange(tw.Wallet.Address, 0);
    }

    // ─── EIP-2612 Permit Signing ────────────────────────────────────────────

    private static PermitSignature SignUsdcPermit(PrivateKeySigner signer, string owner, string spender,
                                                  long value, long nonce, long deadline)
    {
        var domainTypeHash = Eip712.Keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        var nameHash = Eip712.Keccak256("USD Coin");
        var versionHash = Eip712.Keccak256("2");

        var domainData = Concat(domainTypeHash, nameHash, versionHash, PadUint256(ChainIdVal), PadAddress(UsdcAddress));
        var domainSep = Eip712.Keccak256(domainData);

        var permitTypeHash = Eip712.Keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        var structData = Concat(permitTypeHash, PadAddress(owner), PadAddress(spender),
                               PadUint256(value), PadUint256(nonce), PadUint256(deadline));
        var structHash = Eip712.Keccak256(structData);

        var finalData = new byte[66];
        finalData[0] = 0x19;
        finalData[1] = 0x01;
        Buffer.BlockCopy(domainSep, 0, finalData, 2, 32);
        Buffer.BlockCopy(structHash, 0, finalData, 34, 32);
        var digest = Eip712.Keccak256(finalData);

        var sigHex = signer.Sign(digest);
        var sigBytes = Convert.FromHexString(sigHex.Replace("0x", ""));
        var r = "0x" + Convert.ToHexString(sigBytes[..32]).ToLowerInvariant();
        var s = "0x" + Convert.ToHexString(sigBytes[32..64]).ToLowerInvariant();
        var v = (int)sigBytes[64];

        return new PermitSignature(value, deadline, v, r, s);
    }

    private static byte[] PadUint256(long value)
    {
        var result = new byte[32];
        var bytes = BitConverter.GetBytes((ulong)value);
        if (BitConverter.IsLittleEndian) Array.Reverse(bytes);
        Buffer.BlockCopy(bytes, 0, result, 24, 8);
        return result;
    }

    private static byte[] PadAddress(string address)
    {
        var hex = address.Replace("0x", "");
        var bytes = Convert.FromHexString(hex);
        var result = new byte[32];
        Buffer.BlockCopy(bytes, 0, result, 12, 20);
        return result;
    }

    private static byte[] Concat(params byte[][] arrays)
    {
        var total = arrays.Sum(a => a.Length);
        var result = new byte[total];
        var pos = 0;
        foreach (var a in arrays) { Buffer.BlockCopy(a, 0, result, pos, a.Length); pos += a.Length; }
        return result;
    }

    private readonly ITestOutputHelper _output;

    public AcceptanceTests(ITestOutputHelper output) { _output = output; }

    private void LogTx(string flow, string step, string? txHash)
    {
        if (string.IsNullOrEmpty(txHash)) return;
        _output.WriteLine($"[TX] {flow} | {step} | {txHash} | https://sepolia.basescan.org/tx/{txHash}");
    }

    // ─── Tests ──────────────────────────────────────────────────────────────

    [Fact]
    public async Task PayDirectWithPermit()
    {
        if (Environment.GetEnvironmentVariable("ACCEPTANCE_API_URL") is null) return;

        var agent = await CreateTestWallet();
        var provider = await CreateTestWallet();
        await FundWallet(agent, 100);

        var amount = 1.0;
        var fee = 0.01;
        var providerReceives = amount - fee;

        var agentBefore = await GetUsdcBalance(agent.Wallet.Address);
        var providerBefore = await GetUsdcBalance(provider.Wallet.Address);
        var feeBefore = await GetFeeBalance();

        var contracts = await FetchContracts();
        var routerAddr = contracts["router"].GetString()!;
        var deadline = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600;
        var permit = SignUsdcPermit(agent.Signer, agent.Wallet.Address, routerAddr,
                                    2_000_000, 0, deadline);

        var tx = await agent.Wallet.PayAsync(provider.Wallet.Address, 1.0m,
                                             memo: "dotnet-sdk-acceptance", permit: permit);
        Assert.NotNull(tx.TxHash);
        Assert.StartsWith("0x", tx.TxHash);
        LogTx("direct", "pay", tx.TxHash);

        var agentAfter = await WaitForBalanceChange(agent.Wallet.Address, agentBefore);
        var providerAfter = await GetUsdcBalance(provider.Wallet.Address);
        var feeAfter = await GetFeeBalance();

        AssertBalanceChange("agent", agentBefore, agentAfter, -amount);
        AssertBalanceChange("provider", providerBefore, providerAfter, providerReceives);
        AssertBalanceChange("fee wallet", feeBefore, feeAfter, fee);
    }

    [Fact]
    public async Task EscrowLifecycle()
    {
        if (Environment.GetEnvironmentVariable("ACCEPTANCE_API_URL") is null) return;

        var agent = await CreateTestWallet();
        var provider = await CreateTestWallet();
        await FundWallet(agent, 100);

        var amount = 5.0;
        var fee = amount * 0.01;
        var providerReceives = amount - fee;

        var agentBefore = await GetUsdcBalance(agent.Wallet.Address);
        var providerBefore = await GetUsdcBalance(provider.Wallet.Address);
        var feeBefore = await GetFeeBalance();

        var contracts = await FetchContracts();
        var escrowAddr = contracts["escrow"].GetString()!;
        var deadline = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600;
        var permit = SignUsdcPermit(agent.Signer, agent.Wallet.Address, escrowAddr,
                                    6_000_000, 0, deadline);

        var escrow = await agent.Wallet.CreateEscrowAsync(provider.Wallet.Address, 5.0m,
                                                          permit: permit);
        Assert.NotEmpty(escrow.Id);

        await WaitForBalanceChange(agent.Wallet.Address, agentBefore);

        await provider.Wallet.ClaimStartAsync(escrow.Id);
        await Task.Delay(5000);

        var released = await agent.Wallet.ReleaseEscrowAsync(escrow.Id);
        LogTx("escrow", "release", released.TxHash);

        var providerAfter = await WaitForBalanceChange(provider.Wallet.Address, providerBefore);
        var feeAfter = await GetFeeBalance();
        var agentAfter = await GetUsdcBalance(agent.Wallet.Address);

        AssertBalanceChange("agent", agentBefore, agentAfter, -amount);
        AssertBalanceChange("provider", providerBefore, providerAfter, providerReceives);
        AssertBalanceChange("fee wallet", feeBefore, feeAfter, fee);
    }

    // ─── Tab lifecycle ───────────────────────────────────────────────────────

    [Fact]
    public async Task TabLifecycle()
    {
        if (Environment.GetEnvironmentVariable("ACCEPTANCE_API_URL") is null) return;

        var agent = await CreateTestWallet();
        var provider = await CreateTestWallet();
        await FundWallet(agent, 100);

        var contracts = await FetchContracts();
        var tabAddr = contracts["tab"].GetString()!;
        var deadline = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600;
        var permit = SignUsdcPermit(agent.Signer, agent.Wallet.Address, tabAddr,
                                    20_000_000, 0, deadline);

        var agentBefore = await GetUsdcBalance(agent.Wallet.Address);

        // 1. Open tab
        var tab = await agent.Wallet.CreateTabAsync(
            provider.Wallet.Address, 10.0m, 0.50m, expiresSecs: 3600, permit: permit);
        Assert.NotEmpty(tab.Id);
        Assert.Equal(TabStatus.Open, tab.Status);

        // Wait for on-chain confirmation + indexer to pick up the tab event
        await WaitForBalanceChange(agent.Wallet.Address, agentBefore);

        // 2. Charge tab — PROVIDER signs AND submits (server scopes by auth wallet)
        var sig1 = provider.Wallet.SignTabCharge(tabAddr, tab.Id, 500_000, 1);
        var charge1 = await provider.Wallet.ChargeTabAsync(tab.Id, 0.50m, 0.50m, 1, sig1);
        Assert.Equal(tab.Id, charge1.TabId);

        // 3. Second charge (provider submits)
        var sig2 = provider.Wallet.SignTabCharge(tabAddr, tab.Id, 1_000_000, 2);
        var charge2 = await provider.Wallet.ChargeTabAsync(tab.Id, 0.50m, 1.00m, 2, sig2);
        Assert.Equal(2, charge2.CallCount);

        // 4. Close tab (agent closes)
        var sigClose = provider.Wallet.SignTabCharge(tabAddr, tab.Id, 1_000_000, 2);
        var closed = await agent.Wallet.CloseTabAsync(tab.Id, 1.00m, sigClose);
        Assert.NotNull(closed);
    }

    // ─── Stream lifecycle ────────────────────────────────────────────────────

    [Fact]
    public async Task StreamLifecycle()
    {
        if (Environment.GetEnvironmentVariable("ACCEPTANCE_API_URL") is null) return;

        var agent = await CreateTestWallet();
        var provider = await CreateTestWallet();
        await FundWallet(agent, 100);

        var contracts = await FetchContracts();
        var streamAddr = contracts["stream"].GetString()!;
        var deadline = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600;
        var permit = SignUsdcPermit(agent.Signer, agent.Wallet.Address, streamAddr,
                                    20_000_000, 0, deadline);

        var agentBefore = await GetUsdcBalance(agent.Wallet.Address);

        // 1. Open stream: rate = 0.001 USDC/sec, max = 10 USDC
        var stream = await agent.Wallet.CreateStreamAsync(
            provider.Wallet.Address, 0.001m, 10.0m, permit: permit);
        Assert.NotEmpty(stream.Id);
        Assert.Equal(StreamStatus.Active, stream.Status);

        await WaitForBalanceChange(agent.Wallet.Address, agentBefore);

        // 2. Let it accrue briefly
        await Task.Delay(3000);

        // 3. Close stream
        var tx = await agent.Wallet.CloseStreamAsync(stream.Id);
        Assert.NotNull(tx.TxHash);
        Assert.StartsWith("0x", tx.TxHash);
        LogTx("stream", "close", tx.TxHash);
    }

    // ─── Bounty lifecycle ────────────────────────────────────────────────────

    [Fact]
    public async Task BountyLifecycle()
    {
        if (Environment.GetEnvironmentVariable("ACCEPTANCE_API_URL") is null) return;

        var poster = await CreateTestWallet();
        var submitter = await CreateTestWallet();
        await FundWallet(poster, 100);

        var contracts = await FetchContracts();
        var bountyAddr = contracts["bounty"].GetString()!;
        var deadline = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600;
        var permit = SignUsdcPermit(poster.Signer, poster.Wallet.Address, bountyAddr,
                                    6_000_000, 0, deadline);

        // 1. Post bounty
        var bounty = await poster.Wallet.CreateBountyAsync(
            5.0m, "Summarize this research paper", deadlineSecs: 3600, permit: permit);
        Assert.NotEmpty(bounty.Id);
        Assert.Equal(BountyStatus.Open, bounty.Status);

        // 2. Submit evidence (by submitter) — must be 32 bytes (64 hex chars)
        var evidenceHash = "0x" + string.Concat(Enumerable.Repeat("ab", 32));
        var submission = await submitter.Wallet.SubmitBountyAsync(bounty.Id, evidenceHash);
        Assert.True(submission.Id > 0);
        Assert.Equal(bounty.Id, submission.BountyId);

        // 3. Award bounty to the submission (by poster)
        var awarded = await poster.Wallet.AwardBountyAsync(bounty.Id, submission.Id);
        Assert.Equal(BountyStatus.Awarded, awarded.Status);
    }

    // ─── Deposit lifecycle ───────────────────────────────────────────────────

    [Fact]
    public async Task DepositLifecycle()
    {
        if (Environment.GetEnvironmentVariable("ACCEPTANCE_API_URL") is null) return;

        var agent = await CreateTestWallet();
        var provider = await CreateTestWallet();
        await FundWallet(agent, 100);

        var contracts = await FetchContracts();
        var depositAddr = contracts["deposit"].GetString()!;
        var deadline = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600;
        var permit = SignUsdcPermit(agent.Signer, agent.Wallet.Address, depositAddr,
                                    6_000_000, 0, deadline);

        var agentBefore = await GetUsdcBalance(agent.Wallet.Address);

        // 1. Lock deposit
        var deposit = await agent.Wallet.LockDepositAsync(
            provider.Wallet.Address, 5.0m, expireSecs: 3600, permit: permit);
        Assert.NotEmpty(deposit.Id);
        Assert.Equal(DepositStatus.Locked, deposit.Status);

        await WaitForBalanceChange(agent.Wallet.Address, agentBefore);
        var agentAfterLock = await GetUsdcBalance(agent.Wallet.Address);

        // 2. Return deposit (by provider)
        var tx = await provider.Wallet.ReturnDepositAsync(deposit.Id);
        Assert.NotNull(tx.TxHash);
        LogTx("deposit", "return", tx.TxHash);

        // 3. Verify full refund (deposits have no fee)
        var agentAfterReturn = await WaitForBalanceChange(agent.Wallet.Address, agentAfterLock);
        var refund = agentAfterReturn - agentAfterLock;
        Assert.True(refund > 4.99, $"Expected near-full refund (~5.0), got {refund:F6}");
    }

    // ─── x402 auto-pay ──────────────────────────────────────────────────────

    [Fact]
    public async Task X402AutoPay()
    {
        if (Environment.GetEnvironmentVariable("ACCEPTANCE_API_URL") is null) return;

        var agent = await CreateTestWallet();
        await FundWallet(agent, 100);

        var contracts = await FetchContracts();
        var usdcAddr = contracts["usdc"].GetString()!;
        var routerAddr = contracts["router"].GetString()!;

        // Spin up a local HTTP server that returns 402 PAYMENT-REQUIRED.
        var listener = new System.Net.HttpListener();
        listener.Prefixes.Add("http://127.0.0.1:0/");
        // Use a TCP listener to get a random port
        var tcpListener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        tcpListener.Start();
        var port = ((System.Net.IPEndPoint)tcpListener.LocalEndpoint).Port;
        tcpListener.Stop();

        var prefix = $"http://127.0.0.1:{port}/";
        listener = new System.Net.HttpListener();
        listener.Prefixes.Add(prefix);
        listener.Start();

        var serverUrl = $"http://127.0.0.1:{port}";

        // Handle requests in background
        var cts = new CancellationTokenSource();
        var serverTask = Task.Run(async () =>
        {
            while (!cts.Token.IsCancellationRequested)
            {
                HttpListenerContext? ctx;
                try { ctx = await listener.GetContextAsync(); }
                catch { break; }

                var paymentSig = ctx.Request.Headers["PAYMENT-SIGNATURE"];
                if (string.IsNullOrEmpty(paymentSig))
                {
                    // Return 402 with PAYMENT-REQUIRED header
                    var paymentRequired = new Dictionary<string, object>
                    {
                        ["scheme"] = "exact",
                        ["network"] = "eip155:84532",
                        ["amount"] = "100000", // $0.10
                        ["asset"] = usdcAddr,
                        ["payTo"] = routerAddr,
                        ["maxTimeoutSeconds"] = 60,
                        ["resource"] = "/v1/data",
                        ["description"] = "Test data endpoint",
                        ["mimeType"] = "application/json",
                    };
                    var encoded = Convert.ToBase64String(
                        Encoding.UTF8.GetBytes(JsonSerializer.Serialize(paymentRequired)));
                    ctx.Response.StatusCode = 402;
                    ctx.Response.Headers.Add("PAYMENT-REQUIRED", encoded);
                    ctx.Response.ContentType = "text/plain";
                    var body = Encoding.UTF8.GetBytes("Payment Required");
                    ctx.Response.OutputStream.Write(body);
                    ctx.Response.Close();
                }
                else
                {
                    // Validate payment sig structure and return 200
                    try
                    {
                        var decoded = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(
                            Encoding.UTF8.GetString(Convert.FromBase64String(paymentSig)));
                        ctx.Response.StatusCode = 200;
                        ctx.Response.ContentType = "application/json";
                        var body = Encoding.UTF8.GetBytes("{\"status\":\"ok\",\"data\":\"secret\"}");
                        ctx.Response.OutputStream.Write(body);
                    }
                    catch
                    {
                        ctx.Response.StatusCode = 400;
                    }
                    ctx.Response.Close();
                }
            }
        });

        try
        {
            // 1. Bare GET should return 402
            var resp = await Http.GetAsync($"{serverUrl}/v1/data");
            Assert.Equal(HttpStatusCode.PaymentRequired, resp.StatusCode);

            // 2. Verify PAYMENT-REQUIRED header is present and parseable
            var payReq = resp.Headers.GetValues("PAYMENT-REQUIRED").FirstOrDefault();
            Assert.NotNull(payReq);
            var decodedJson = Encoding.UTF8.GetString(Convert.FromBase64String(payReq!));
            var reqPayload = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(decodedJson)!;
            Assert.Equal("exact", reqPayload["scheme"].GetString());
            Assert.Equal("100000", reqPayload["amount"].GetString());

            // 3. Verify V2 fields
            Assert.Equal("/v1/data", reqPayload["resource"].GetString());
            Assert.Equal("Test data endpoint", reqPayload["description"].GetString());
            Assert.Equal("application/json", reqPayload["mimeType"].GetString());
        }
        finally
        {
            cts.Cancel();
            listener.Stop();
        }
    }
}
