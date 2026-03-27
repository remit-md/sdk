using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RemitMd;

/// <summary>
/// Low-level HTTP transport used by <see cref="Wallet"/>.
/// Handles EIP-712 request signing, auth headers, retries, and structured error parsing.
/// </summary>
internal sealed class ApiClient : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
        Converters = { new JsonStringEnumConverter(new SnakeCaseNamingPolicy()) },
    };

    private readonly HttpClient _http;
    private readonly IRemitSigner _signer;
    private readonly long _chainId;
    private readonly string _routerAddress;

    internal ApiClient(IRemitSigner signer, long chainId, string routerAddress, string baseUrl)
    {
        _signer        = signer;
        _chainId       = chainId;
        _routerAddress = routerAddress ?? string.Empty;

        _http = new HttpClient { BaseAddress = new Uri(baseUrl) };
        _http.DefaultRequestHeaders.Accept.Add(
            new MediaTypeWithQualityHeaderValue("application/json"));
        _http.Timeout = TimeSpan.FromSeconds(30);
    }

    /// <summary>Makes a GET request and deserializes the response.</summary>
    internal async Task<T> GetAsync<T>(string path, CancellationToken ct)
    {
        var response = await ExecuteWithRetryAsync(
            () => SendSignedAsync(HttpMethod.Get, path, body: null, idempotencyKey: null, ct), ct);
        return await DeserializeAsync<T>(response);
    }

    /// <summary>Makes a POST request with a JSON body and deserializes the response.</summary>
    internal async Task<T> PostAsync<T>(string path, object body, CancellationToken ct)
    {
        // Generate idempotency key once per request (stable across retries).
        var keyBytes = RandomNumberGenerator.GetBytes(16);
        var idempotencyKey = Convert.ToHexString(keyBytes).ToLowerInvariant();
        var response = await ExecuteWithRetryAsync(
            () => SendSignedAsync(HttpMethod.Post, path, body, idempotencyKey, ct), ct);
        return await DeserializeAsync<T>(response);
    }

    private async Task<HttpResponseMessage> SendSignedAsync(
        HttpMethod method,
        string path,
        object? body,
        string? idempotencyKey,
        CancellationToken ct)
    {
        // Generate fresh nonce and timestamp for each attempt (replay protection).
        var nonceBytes = RandomNumberGenerator.GetBytes(32);
        var nonceHex   = "0x" + Convert.ToHexString(nonceBytes).ToLowerInvariant();
        var timestamp  = (ulong)DateTimeOffset.UtcNow.ToUnixTimeSeconds();

        // Compute EIP-712 hash and sign it.
        var digest    = Eip712.ComputeRequestDigest(_chainId, _routerAddress, method.Method, path, timestamp, nonceBytes);
        var signature = _signer.Sign(digest);

        var req = new HttpRequestMessage(method, path);
        req.Headers.Add("X-Remit-Agent",     _signer.Address);
        req.Headers.Add("X-Remit-Nonce",     nonceHex);
        req.Headers.Add("X-Remit-Timestamp", timestamp.ToString());
        req.Headers.Add("X-Remit-Signature", signature);

        if (idempotencyKey is not null)
            req.Headers.Add("X-Idempotency-Key", idempotencyKey);

        if (body is not null)
            req.Content = JsonContent.Create(body, options: JsonOptions);

        return await _http.SendAsync(req, ct);
    }

    private static async Task<HttpResponseMessage> ExecuteWithRetryAsync(
        Func<Task<HttpResponseMessage>> request,
        CancellationToken ct,
        int maxRetries = 3)
    {
        var delay = TimeSpan.FromMilliseconds(200);
        Exception? lastEx = null;

        for (var attempt = 0; attempt < maxRetries; attempt++)
        {
            try
            {
                var response = await request();

                // Retry on 429 (rate-limit) and 5xx with exponential backoff.
                if (response.StatusCode == HttpStatusCode.TooManyRequests ||
                    (int)response.StatusCode >= 500)
                {
                    if (attempt == maxRetries - 1)
                        return response; // surface the error on final attempt

                    await Task.Delay(delay, ct);
                    delay *= 2;
                    continue;
                }

                return response;
            }
            catch (HttpRequestException ex) when (attempt < maxRetries - 1)
            {
                lastEx = ex;
                await Task.Delay(delay, ct);
                delay *= 2;
            }
            catch (TaskCanceledException) { throw; } // respect cancellation
        }

        throw new RemitError(ErrorCodes.NetworkError,
            $"Request failed after {maxRetries} attempts: {lastEx?.Message}",
            new Dictionary<string, object> { ["retries"] = maxRetries });
    }

    private static async Task<T> DeserializeAsync<T>(HttpResponseMessage response)
    {
        var body = await response.Content.ReadAsStringAsync();

        if (!response.IsSuccessStatusCode)
        {
            // Try to parse a structured API error.
            // Supports both flat {"code":"...", "message":"..."} and
            // nested {"error": {"code":"...", "message":"..."}} formats.
            ApiError? err = null;
            try
            {
                err = JsonSerializer.Deserialize<ApiError>(body, JsonOptions);
                // Check for nested {"error": {...}} format
                if (err?.Code is null && err?.Nested is not null)
                    err = err.Nested;
            }
            catch { /* fall through to generic error */ }

            if (err?.Code is not null)
            {
                throw new RemitError(err.Code, err.Message ?? err.Code,
                    err.Context, (int)response.StatusCode);
            }

            var code = response.StatusCode == HttpStatusCode.TooManyRequests
                ? ErrorCodes.RateLimited
                : ErrorCodes.ServerError;

            throw new RemitError(code,
                $"HTTP {(int)response.StatusCode}: {response.ReasonPhrase}. Body: {Truncate(body, 200)}",
                null, (int)response.StatusCode);
        }

        try
        {
            return JsonSerializer.Deserialize<T>(body, JsonOptions)
                ?? throw new RemitError(ErrorCodes.ServerError, "Server returned null response.");
        }
        catch (JsonException ex)
        {
            throw new RemitError(ErrorCodes.ServerError,
                $"Failed to parse API response: {ex.Message}. Body: {Truncate(body, 200)}");
        }
    }

    private static string Truncate(string s, int max) =>
        s.Length <= max ? s : s[..max] + "…";

    public void Dispose() => _http.Dispose();

    // ─── Wire types ───────────────────────────────────────────────────────────

    private sealed record ApiError(
        [property: JsonPropertyName("code")] string? Code,
        [property: JsonPropertyName("message")] string? Message,
        [property: JsonPropertyName("context")] Dictionary<string, object>? Context,
        [property: JsonPropertyName("error")] ApiError? Nested = null
    );
}

/// <summary>
/// Internal transport abstraction - allows MockRemit to replace the HTTP layer.
/// </summary>
internal interface IRemitTransport
{
    Task<T> GetAsync<T>(string path, CancellationToken ct);
    Task<T> PostAsync<T>(string path, object body, CancellationToken ct);
}

/// <summary>
/// Converts PascalCase names to snake_case for JSON serialization.
/// Provides cross-TFM compatibility (JsonNamingPolicy.SnakeCaseLower is .NET 8+ only).
/// </summary>
internal sealed class SnakeCaseNamingPolicy : JsonNamingPolicy
{
    public override string ConvertName(string name)
    {
        if (string.IsNullOrEmpty(name)) return name;

        var sb = new System.Text.StringBuilder(name.Length + 4);
        for (var i = 0; i < name.Length; i++)
        {
            var c = name[i];
            if (char.IsUpper(c))
            {
                if (i > 0) sb.Append('_');
                sb.Append(char.ToLowerInvariant(c));
            }
            else
            {
                sb.Append(c);
            }
        }
        return sb.ToString();
    }
}

/// <summary>Adapts <see cref="ApiClient"/> to <see cref="IRemitTransport"/>.</summary>
internal sealed class HttpTransport : IRemitTransport, IDisposable
{
    private readonly ApiClient _client;
    internal HttpTransport(IRemitSigner signer, long chainId, string routerAddress, string baseUrl)
        => _client = new ApiClient(signer, chainId, routerAddress, baseUrl);

    public Task<T> GetAsync<T>(string path, CancellationToken ct)   => _client.GetAsync<T>(path, ct);
    public Task<T> PostAsync<T>(string path, object body, CancellationToken ct) => _client.PostAsync<T>(path, body, ct);
    public void Dispose() => _client.Dispose();
}
