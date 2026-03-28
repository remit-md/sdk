using System;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;
using Xunit.Abstractions;

namespace RemitMd.Tests;

/// <summary>
/// Compliance tests: .NET SDK against a real running server.
///
/// Tests return early (pass vacuously) when the server is not reachable.
/// Boot the server with:
///   docker compose -f docker-compose.compliance.yml up -d
///
/// Environment variables:
///   REMIT_TEST_SERVER_URL  (default: http://localhost:3000)
///   REMIT_ROUTER_ADDRESS   (default: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8)
/// </summary>
public class ComplianceTests
{
    private static readonly string ServerUrl =
        Environment.GetEnvironmentVariable("REMIT_TEST_SERVER_URL") ?? "http://localhost:3000";
    private static readonly string RouterAddress =
        Environment.GetEnvironmentVariable("REMIT_ROUTER_ADDRESS") ??
        "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

    private static readonly HttpClient Http = new()
    {
        Timeout = TimeSpan.FromSeconds(10),
    };

    private static readonly SemaphoreSlim PayerLock = new(1, 1);
    private static Wallet? _sharedPayer;

    // ─── Server availability ──────────────────────────────────────────────────

    private static readonly Lazy<Task<bool>> ServerAvailable = new(async () =>
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            var resp = await Http.GetAsync(ServerUrl + "/health", cts.Token);
            return resp.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    });

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static (string PrivateKey, string WalletAddress) GenerateWallet()
    {
        var keyBytes = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
        var privateKey = "0x" + Convert.ToHexString(keyBytes).ToLowerInvariant();
        var wallet = MakeWallet(privateKey);
        Console.WriteLine($"[COMPLIANCE] wallet created: {wallet.Address} (chain=84532)");
        return (privateKey, wallet.Address);
    }

    private static async Task FundWallet(string walletAddress)
    {
        Console.WriteLine($"[COMPLIANCE] minting 1000 USDC to {walletAddress} ...");
        var resp = await Http.PostAsJsonAsync($"{ServerUrl}/api/v1/mint", new
        {
            wallet = walletAddress,
            amount = 1000,
        });
        resp.EnsureSuccessStatusCode();
        var body = await resp.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(body);
        Assert.True(doc.RootElement.TryGetProperty("tx_hash", out var txHashElem),
            $"mint response must contain tx_hash");
        Console.WriteLine($"[COMPLIANCE] mint: 1000 USDC -> {walletAddress} tx={txHashElem}");
    }

    private static Wallet MakeWallet(string privateKey) =>
        new Wallet(privateKey, chain: "base", testnet: true,
            baseUrl: ServerUrl, routerAddress: RouterAddress);

    private async Task<Wallet> GetSharedPayer()
    {
        if (_sharedPayer is not null) return _sharedPayer;

        await PayerLock.WaitAsync();
        try
        {
            if (_sharedPayer is not null) return _sharedPayer;

            Console.WriteLine("[COMPLIANCE] creating shared payer wallet ...");
            var (pk, addr) = GenerateWallet();
            await FundWallet(addr);
            _sharedPayer = MakeWallet(pk);
            Console.WriteLine($"[COMPLIANCE] shared payer ready: {_sharedPayer.Address}");
        }
        finally
        {
            PayerLock.Release();
        }
        return _sharedPayer!;
    }

    // ─── Auth tests ───────────────────────────────────────────────────────────

    [Fact]
    public async Task Compliance_AuthenticatedRequest_ReturnsBalance_Not401()
    {
        if (!await ServerAvailable.Value)
        {
            Console.WriteLine("[COMPLIANCE] server not reachable — skipping auth test");
            return;
        }

        Console.WriteLine("[COMPLIANCE] === AuthenticatedRequest_ReturnsBalance_Not401 ===");
        var (pk, _) = GenerateWallet();
        var wallet = MakeWallet(pk);

        // BalanceAsync() makes an authenticated GET - will throw on 401.
        Console.WriteLine($"[COMPLIANCE] fetching balance for {wallet.Address} ...");
        var balance = await wallet.BalanceAsync();
        Assert.NotNull(balance);
        Console.WriteLine($"[COMPLIANCE] balance: {balance.Usdc} USDC (address={balance.Address}, chainId={balance.ChainId})");
    }

    [Fact]
    public async Task Compliance_UnauthenticatedRequest_Returns401()
    {
        if (!await ServerAvailable.Value)
        {
            Console.WriteLine("[COMPLIANCE] server not reachable — skipping 401 test");
            return;
        }

        Console.WriteLine("[COMPLIANCE] === UnauthenticatedRequest_Returns401 ===");
        Console.WriteLine("[COMPLIANCE] sending unauthenticated POST to /api/v1/payments/direct ...");
        var resp = await Http.PostAsJsonAsync($"{ServerUrl}/api/v1/payments/direct", new
        {
            to     = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
            amount = "1.000000",
        });
        Console.WriteLine($"[COMPLIANCE] response status: {(int)resp.StatusCode}");
        Assert.Equal(401, (int)resp.StatusCode);
        Console.WriteLine("[COMPLIANCE] confirmed: unauthenticated request returned 401");
    }

    // ─── Payment tests ────────────────────────────────────────────────────────

    [Fact]
    public async Task Compliance_PayDirect_HappyPath_ReturnsTxHash()
    {
        if (!await ServerAvailable.Value)
        {
            Console.WriteLine("[COMPLIANCE] server not reachable — skipping pay direct test");
            return;
        }

        Console.WriteLine("[COMPLIANCE] === PayDirect_HappyPath_ReturnsTxHash ===");
        var payer = await GetSharedPayer();
        var (_, payeeAddr) = GenerateWallet();

        Console.WriteLine($"[COMPLIANCE] pay: 5.0 USDC {payer.Address} -> {payeeAddr} ...");
        var tx = await payer.PayAsync(payeeAddr, 5.0m, memo: "dotnet compliance test");

        Assert.False(string.IsNullOrEmpty(tx.TxHash),
            "PayAsync() must return a non-empty TxHash");
        Console.WriteLine($"[COMPLIANCE] pay: 5.0 USDC {payer.Address} -> {payeeAddr} tx={tx.TxHash} id={tx.Id}");
    }

    [Fact]
    public async Task Compliance_PayDirect_BelowMinimum_ThrowsRemitError()
    {
        if (!await ServerAvailable.Value)
        {
            Console.WriteLine("[COMPLIANCE] server not reachable — skipping below-minimum test");
            return;
        }

        Console.WriteLine("[COMPLIANCE] === PayDirect_BelowMinimum_ThrowsRemitError ===");
        var payer = await GetSharedPayer();
        var (_, payeeAddr) = GenerateWallet();

        Console.WriteLine($"[COMPLIANCE] pay: 0.0001 USDC {payer.Address} -> {payeeAddr} (expect error) ...");
        var ex = await Assert.ThrowsAsync<RemitError>(async () =>
            await payer.PayAsync(payeeAddr, 0.0001m));
        Console.WriteLine($"[COMPLIANCE] correctly threw RemitError: {ex.Message}");
    }
}
