// .NET SDK acceptance tests: payDirect + escrow lifecycle on live Base Sepolia.
//
// Run: dotnet test --filter "FullyQualifiedName~AcceptanceTests" --no-build
//
// Env vars (all optional):
//   ACCEPTANCE_API_URL  — default: https://remit.md
//   ACCEPTANCE_RPC_URL  — default: https://sepolia.base.org

using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Nethereum.Signer;
using RemitMd;
using Xunit;

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
        var resp = await Http.GetStringAsync($"{ApiUrl}/api/v0/contracts");
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

        await agent.Wallet.ReleaseEscrowAsync(escrow.Id);

        var providerAfter = await WaitForBalanceChange(provider.Wallet.Address, providerBefore);
        var feeAfter = await GetFeeBalance();
        var agentAfter = await GetUsdcBalance(agent.Wallet.Address);

        AssertBalanceChange("agent", agentBefore, agentAfter, -amount);
        AssertBalanceChange("provider", providerBefore, providerAfter, providerReceives);
        AssertBalanceChange("fee wallet", feeBefore, feeAfter, fee);
    }
}
