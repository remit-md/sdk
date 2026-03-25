using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
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
/// 3. Builds and signs an EIP-3009 <c>transferWithAuthorization</c>
/// 4. Base64-encodes the <c>PAYMENT-SIGNATURE</c> header
/// 5. Retries the original request with payment attached
/// </summary>
public sealed class X402Client : IDisposable
{
    private readonly IRemitSigner _signer;
    private readonly string _address;
    private readonly HttpClient _http;

    /// <summary>Maximum USDC amount to auto-pay per request.</summary>
    public decimal MaxAutoPayUsdc { get; }

    /// <summary>The last PAYMENT-REQUIRED decoded before payment. Useful for logging/display.</summary>
    public PaymentRequired? LastPayment { get; private set; }

    /// <summary>
    /// Creates an X402Client.
    /// </summary>
    /// <param name="signer">Signer used for EIP-3009 authorization signatures.</param>
    /// <param name="address">Checksummed payer address — must match the signer's public key.</param>
    /// <param name="maxAutoPayUsdc">Maximum USDC amount to auto-pay per request (default: 0.10).</param>
    public X402Client(IRemitSigner signer, string? address = null, decimal maxAutoPayUsdc = 0.10m)
    {
        _signer = signer;
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

        // 4. Parse chainId from CAIP-2 network string (e.g. "eip155:84532" → 84532)
        var chainIdStr = required.Network.Split(':')[1];
        var chainId = long.Parse(chainIdStr);

        // 5. Build EIP-3009 authorization fields
        var nowSecs = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var validBefore = nowSecs + (required.MaxTimeoutSeconds ?? 60);
        var nonceBytes = RandomNumberGenerator.GetBytes(32);
        var nonceHex = "0x" + Convert.ToHexString(nonceBytes).ToLowerInvariant();

        // EIP-712 domain: USD Coin / version 2
        var domainTypeHash = Eip712.Keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        var nameHash = Eip712.Keccak256("USD Coin");
        var versionHash = Eip712.Keccak256("2");
        var domainData = ConcatBytes(domainTypeHash, nameHash, versionHash,
            PadUint256Long(chainId), PadAddressBytes(required.Asset));
        var domainSep = Eip712.Keccak256(domainData);

        // TransferWithAuthorization struct hash
        var typeHash = Eip712.Keccak256(
            "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");
        var structData = ConcatBytes(typeHash,
            PadAddressBytes(_address),
            PadAddressBytes(required.PayTo),
            PadUint256Long(amountBaseUnits),
            PadUint256Long(0), // validAfter = 0
            PadUint256Long(validBefore),
            nonceBytes);
        var structHash = Eip712.Keccak256(structData);

        // Final EIP-712 digest
        var payload = new byte[66];
        payload[0] = 0x19;
        payload[1] = 0x01;
        Buffer.BlockCopy(domainSep, 0, payload, 2, 32);
        Buffer.BlockCopy(structHash, 0, payload, 34, 32);
        var digest = Eip712.Keccak256(payload);

        var signature = _signer.Sign(digest);

        // 6. Build PAYMENT-SIGNATURE JSON payload
        var paymentPayload = new
        {
            scheme = required.Scheme,
            network = required.Network,
            x402Version = 1,
            payload = new
            {
                signature,
                authorization = new
                {
                    from = _address,
                    to = required.PayTo,
                    value = required.Amount,
                    validAfter = "0",
                    validBefore = validBefore.ToString(),
                    nonce = nonceHex,
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

    // ─── Byte helpers ────────────────────────────────────────────────────────

    private static byte[] PadUint256Long(long value)
    {
        var result = new byte[32];
        var bytes = BitConverter.GetBytes((ulong)value);
        if (BitConverter.IsLittleEndian) Array.Reverse(bytes);
        Buffer.BlockCopy(bytes, 0, result, 24, 8);
        return result;
    }

    private static byte[] PadAddressBytes(string address)
    {
        var hex = address.Replace("0x", "").Replace("0X", "");
        var bytes = Convert.FromHexString(hex);
        var result = new byte[32];
        Buffer.BlockCopy(bytes, 0, result, 12, 20);
        return result;
    }

    private static byte[] ConcatBytes(params byte[][] arrays)
    {
        var total = arrays.Sum(a => a.Length);
        var result = new byte[total];
        var pos = 0;
        foreach (var a in arrays) { Buffer.BlockCopy(a, 0, result, pos, a.Length); pos += a.Length; }
        return result;
    }

    public void Dispose() => _http.Dispose();
}
