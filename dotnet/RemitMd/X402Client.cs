using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RemitMd;

/// <summary>Raised when an x402 payment amount exceeds the configured auto-pay limit.</summary>
public sealed class AllowanceExceededError : Exception
{
    /// <summary>Requested amount in USDC.</summary>
    public decimal AmountUsdc { get; }

    /// <summary>Configured auto-pay limit in USDC.</summary>
    public decimal LimitUsdc { get; }

    public AllowanceExceededError(decimal amountUsdc, decimal limitUsdc)
        : base($"x402 payment {amountUsdc:F6} USDC exceeds auto-pay limit {limitUsdc:F6} USDC")
    {
        AmountUsdc = amountUsdc;
        LimitUsdc = limitUsdc;
    }
}

/// <summary>Shape of the base64-decoded PAYMENT-REQUIRED header (V2).</summary>
public sealed class PaymentRequired
{
    [JsonPropertyName("scheme")] public string Scheme { get; set; } = "";
    [JsonPropertyName("network")] public string Network { get; set; } = "";
    [JsonPropertyName("amount")] public string Amount { get; set; } = "0";
    [JsonPropertyName("asset")] public string Asset { get; set; } = "";
    [JsonPropertyName("payTo")] public string PayTo { get; set; } = "";
    [JsonPropertyName("maxTimeoutSeconds")] public int? MaxTimeoutSeconds { get; set; }
    [JsonPropertyName("resource")] public string? Resource { get; set; }
    [JsonPropertyName("description")] public string? Description { get; set; }
    [JsonPropertyName("mimeType")] public string? MimeType { get; set; }
}

/// <summary>
/// <c>fetch</c> wrapper that auto-handles HTTP 402 Payment Required responses.
///
/// On receiving a 402, the client:
/// 1. Decodes the <c>PAYMENT-REQUIRED</c> header (base64 JSON)
/// 2. Checks the amount is within <see cref="MaxAutoPayUsdc"/>
/// 3. Calls <c>/x402/prepare</c> to get the EIP-3009 hash and authorization fields
/// 4. Signs the hash and builds the <c>PAYMENT-SIGNATURE</c> header
/// 5. Retries the original request with payment attached
/// </summary>
public sealed class X402Client : IDisposable
{
    private readonly IRemitSigner _signer;
    private readonly string _address;
    private readonly IRemitTransport _apiTransport;
    private readonly HttpClient _http;

    /// <summary>Maximum USDC amount to auto-pay per request.</summary>
    public decimal MaxAutoPayUsdc { get; }

    /// <summary>The last PAYMENT-REQUIRED decoded before payment. Useful for logging/display.</summary>
    public PaymentRequired? LastPayment { get; private set; }

    /// <summary>
    /// Creates an X402Client.
    /// </summary>
    /// <param name="signer">Signer used for EIP-3009 authorization signatures.</param>
    /// <param name="apiTransport">Transport for calling <c>/x402/prepare</c> on the facilitator.</param>
    /// <param name="address">Checksummed payer address - must match the signer's public key.</param>
    /// <param name="maxAutoPayUsdc">Maximum USDC amount to auto-pay per request (default: 0.10).</param>
    public X402Client(IRemitSigner signer, IRemitTransport apiTransport, string? address = null, decimal maxAutoPayUsdc = 0.10m)
    {
        _signer = signer;
        _apiTransport = apiTransport;
        _address = address ?? signer.Address;
        MaxAutoPayUsdc = maxAutoPayUsdc;
        _http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
    }

    /// <summary>Make a fetch request, auto-paying any 402 responses within the configured limit.</summary>
    public async Task<HttpResponseMessage> FetchAsync(string url, HttpRequestMessage? template = null, CancellationToken ct = default)
    {
        var request = template ?? new HttpRequestMessage(HttpMethod.Get, url);
        if (request.RequestUri is null)
            request.RequestUri = new Uri(url);

        var response = await _http.SendAsync(request, ct);
        if (response.StatusCode == HttpStatusCode.PaymentRequired)
            return await Handle402Async(url, response, template, ct);

        return response;
    }

    private async Task<HttpResponseMessage> Handle402Async(string url, HttpResponseMessage response, HttpRequestMessage? template, CancellationToken ct)
    {
        // 1. Decode PAYMENT-REQUIRED header
        var raw = response.Headers.TryGetValues("PAYMENT-REQUIRED", out var values)
            ? values.FirstOrDefault()
            : response.Headers.TryGetValues("payment-required", out var lowerValues)
                ? lowerValues.FirstOrDefault()
                : null;

        if (string.IsNullOrEmpty(raw))
            throw new InvalidOperationException("402 response missing PAYMENT-REQUIRED header");

        var jsonBytes = Convert.FromBase64String(raw);
        var required = JsonSerializer.Deserialize<PaymentRequired>(Encoding.UTF8.GetString(jsonBytes))
            ?? throw new InvalidOperationException("Failed to parse PAYMENT-REQUIRED header");

        // 2. Only "exact" scheme supported
        if (required.Scheme != "exact")
            throw new InvalidOperationException($"Unsupported x402 scheme: {required.Scheme}");

        LastPayment = required;

        // 3. Check auto-pay limit
        var amountBaseUnits = long.Parse(required.Amount);
        var amountUsdc = amountBaseUnits / 1_000_000m;
        if (amountUsdc > MaxAutoPayUsdc)
            throw new AllowanceExceededError(amountUsdc, MaxAutoPayUsdc);

        // 4. Call /x402/prepare to get the hash + authorization fields
        var prepareData = await _apiTransport.PostAsync<JsonElement>(
            "/api/v1/x402/prepare",
            new { payment_required = raw, payer = _address },
            ct);

        // 5. Sign the hash
        var hashHex = prepareData.GetProperty("hash").GetString()
            ?? throw new InvalidOperationException("x402/prepare returned no hash");
        var hashBytes = Convert.FromHexString(hashHex.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? hashHex[2..] : hashHex);
        var signature = _signer.Sign(hashBytes);

        // 6. Build PAYMENT-SIGNATURE JSON payload from prepare response
        var network = required.Network;
        var paymentPayload = new
        {
            scheme = required.Scheme,
            network,
            x402Version = 1,
            payload = new
            {
                signature,
                authorization = new
                {
                    from = prepareData.GetProperty("from").GetString(),
                    to = prepareData.GetProperty("to").GetString(),
                    value = prepareData.GetProperty("value").GetString(),
                    validAfter = prepareData.GetProperty("valid_after").GetString(),
                    validBefore = prepareData.GetProperty("valid_before").GetString(),
                    nonce = prepareData.GetProperty("nonce").GetString(),
                },
            },
        };
        var paymentJson = JsonSerializer.Serialize(paymentPayload);
        var paymentHeader = Convert.ToBase64String(Encoding.UTF8.GetBytes(paymentJson));

        // 7. Retry with PAYMENT-SIGNATURE header
        var retryRequest = new HttpRequestMessage(template?.Method ?? HttpMethod.Get, url);
        retryRequest.Headers.Add("PAYMENT-SIGNATURE", paymentHeader);
        if (template?.Content is not null)
            retryRequest.Content = template.Content;

        return await _http.SendAsync(retryRequest, ct);
    }

    public void Dispose() => _http.Dispose();
}
