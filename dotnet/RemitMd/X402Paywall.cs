using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RemitMd;

/// <summary>Result of <see cref="X402Paywall.CheckAsync"/>.</summary>
public sealed class CheckResult
{
    /// <summary>Whether the payment signature is valid.</summary>
    [JsonPropertyName("isValid")]
    public bool IsValid { get; set; }

    /// <summary>Reason the payment was rejected (when <see cref="IsValid"/> is false).</summary>
    [JsonPropertyName("invalidReason")]
    public string? InvalidReason { get; set; }
}

/// <summary>
/// x402 paywall for service providers.
///
/// Providers use this class to:
/// <list type="bullet">
///   <item>Return HTTP 402 responses with properly formatted <c>PAYMENT-REQUIRED</c> headers</item>
///   <item>Verify incoming <c>PAYMENT-SIGNATURE</c> headers against the remit.md facilitator</item>
/// </list>
/// </summary>
public sealed class X402Paywall : IDisposable
{
    private readonly string _walletAddress;
    private readonly string _amountBaseUnits;
    private readonly string _network;
    private readonly string _asset;
    private readonly string _facilitatorUrl;
    private readonly string _facilitatorToken;
    private readonly int _maxTimeoutSeconds;
    private readonly string? _resource;
    private readonly string? _description;
    private readonly string? _mimeType;
    private readonly HttpClient _http;

    /// <summary>
    /// Creates an X402 paywall for gating endpoints behind USDC payments.
    /// </summary>
    /// <param name="walletAddress">Provider's checksummed Ethereum address (the payTo field).</param>
    /// <param name="amountUsdc">Price per request in USDC (e.g. 0.001).</param>
    /// <param name="network">CAIP-2 network string (e.g. "eip155:84532" for Base Sepolia).</param>
    /// <param name="asset">USDC contract address on the target network.</param>
    /// <param name="facilitatorUrl">Base URL of the remit.md facilitator (default: "https://remit.md").</param>
    /// <param name="facilitatorToken">Bearer JWT for authenticating calls to /api/v1/x402/verify.</param>
    /// <param name="maxTimeoutSeconds">How long the payment authorization remains valid (default: 60).</param>
    /// <param name="resource">V2 - URL or path of the resource being protected.</param>
    /// <param name="description">V2 - Human-readable description of what the payment is for.</param>
    /// <param name="mimeType">V2 - MIME type of the resource (e.g. "application/json").</param>
    public X402Paywall(
        string walletAddress,
        decimal amountUsdc,
        string network,
        string asset,
        string facilitatorUrl = "https://remit.md",
        string facilitatorToken = "",
        int maxTimeoutSeconds = 60,
        string? resource = null,
        string? description = null,
        string? mimeType = null)
    {
        _walletAddress = walletAddress;
        _amountBaseUnits = ((long)Math.Round(amountUsdc * 1_000_000m)).ToString();
        _network = network;
        _asset = asset;
        _facilitatorUrl = facilitatorUrl.TrimEnd('/');
        _facilitatorToken = facilitatorToken;
        _maxTimeoutSeconds = maxTimeoutSeconds;
        _resource = resource;
        _description = description;
        _mimeType = mimeType;
        _http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
    }

    /// <summary>Return the base64-encoded JSON <c>PAYMENT-REQUIRED</c> header value.</summary>
    public string PaymentRequiredHeader()
    {
        var payload = new Dictionary<string, object>
        {
            ["scheme"] = "exact",
            ["network"] = _network,
            ["amount"] = _amountBaseUnits,
            ["asset"] = _asset,
            ["payTo"] = _walletAddress,
            ["maxTimeoutSeconds"] = _maxTimeoutSeconds,
        };
        if (_resource is not null) payload["resource"] = _resource;
        if (_description is not null) payload["description"] = _description;
        if (_mimeType is not null) payload["mimeType"] = _mimeType;

        var json = JsonSerializer.Serialize(payload);
        return Convert.ToBase64String(Encoding.UTF8.GetBytes(json));
    }

    /// <summary>
    /// Check whether a <c>PAYMENT-SIGNATURE</c> header represents a valid payment.
    /// Calls the remit.md facilitator's <c>/api/v1/x402/verify</c> endpoint.
    /// </summary>
    /// <param name="paymentSig">The raw header value (base64 JSON), or null if absent.</param>
    /// <returns><see cref="CheckResult"/> indicating validity.</returns>
    public async Task<CheckResult> CheckAsync(string? paymentSig, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(paymentSig))
            return new CheckResult { IsValid = false };

        object paymentPayload;
        try
        {
            var decoded = Encoding.UTF8.GetString(Convert.FromBase64String(paymentSig));
            paymentPayload = JsonSerializer.Deserialize<object>(decoded)
                ?? throw new InvalidOperationException();
        }
        catch
        {
            return new CheckResult { IsValid = false, InvalidReason = "INVALID_PAYLOAD" };
        }

        var body = new
        {
            paymentPayload,
            paymentRequired = new
            {
                scheme = "exact",
                network = _network,
                amount = _amountBaseUnits,
                asset = _asset,
                payTo = _walletAddress,
                maxTimeoutSeconds = _maxTimeoutSeconds,
            },
        };

        try
        {
            var request = new HttpRequestMessage(HttpMethod.Post,
                $"{_facilitatorUrl}/api/v1/x402/verify");
            request.Content = new StringContent(
                JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
            if (!string.IsNullOrEmpty(_facilitatorToken))
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _facilitatorToken);

            var resp = await _http.SendAsync(request, ct);
            if (!resp.IsSuccessStatusCode)
                return new CheckResult { IsValid = false, InvalidReason = "FACILITATOR_ERROR" };

            var resultJson = await resp.Content.ReadAsStringAsync(ct);
            var result = JsonSerializer.Deserialize<CheckResult>(resultJson);
            return result ?? new CheckResult { IsValid = false, InvalidReason = "FACILITATOR_ERROR" };
        }
        catch
        {
            return new CheckResult { IsValid = false, InvalidReason = "FACILITATOR_ERROR" };
        }
    }

    public void Dispose() => _http.Dispose();
}
