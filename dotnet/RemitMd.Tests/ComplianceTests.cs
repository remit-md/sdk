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
        return (privateKey, wallet.Address);
    }

    private static async Task FundWallet(string walletAddress)
    {
        var resp = await Http.PostAsJsonAsync($"{ServerUrl}/api/v0/mint", new
        {
            wallet = walletAddress,
            amount = 1000,
        });
        resp.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
        Assert.True(doc.RootElement.TryGetProperty("tx_hash", out _),
            $"mint response must contain tx_hash");
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

            var (pk, addr) = GenerateWallet();
            await FundWallet(addr);
            _sharedPayer = MakeWallet(pk);
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
            // Server not reachable — pass vacuously (CI job only runs when server is up).
            return;
        }

        var (pk, _) = GenerateWallet();
        var wallet = MakeWallet(pk);

        // BalanceAsync() makes an authenticated GET — will throw on 401.
        var balance = await wallet.BalanceAsync();
        Assert.NotNull(balance);
    }

    [Fact]
    public async Task Compliance_UnauthenticatedRequest_Returns401()
    {
        if (!await ServerAvailable.Value) return;

        var resp = await Http.PostAsJsonAsync($"{ServerUrl}/api/v0/payments/direct", new
        {
            to     = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
            amount = "1.000000",
        });
        Assert.Equal(401, (int)resp.StatusCode);
    }

    // ─── Payment tests ────────────────────────────────────────────────────────

    [Fact]
    public async Task Compliance_PayDirect_HappyPath_ReturnsTxHash()
    {
        if (!await ServerAvailable.Value) return;

        var payer = await GetSharedPayer();
        var (_, payeeAddr) = GenerateWallet();

        var tx = await payer.PayAsync(payeeAddr, 5.0m, memo: "dotnet compliance test");

        Assert.False(string.IsNullOrEmpty(tx.TxHash),
            "PayAsync() must return a non-empty TxHash");
    }

    [Fact]
    public async Task Compliance_PayDirect_BelowMinimum_ThrowsRemitError()
    {
        if (!await ServerAvailable.Value) return;

        var payer = await GetSharedPayer();
        var (_, payeeAddr) = GenerateWallet();

        await Assert.ThrowsAsync<RemitError>(async () =>
            await payer.PayAsync(payeeAddr, 0.0001m));
    }
}
