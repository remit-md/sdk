using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace RemitMd;

/// <summary>
/// Signer backed by a local HTTP signing server.
///
/// Delegates signing to an HTTP server on localhost (typically
/// <c>http://127.0.0.1:7402</c>). The signer server holds the encrypted key;
/// this adapter only needs a bearer token and URL.
///
/// <para>
/// <b>Security:</b> The bearer token is stored in a private field and is
/// never exposed through <see cref="ToString"/> or exception messages.
/// </para>
///
/// <example>
/// <code>
/// var signer = new HttpSigner("http://127.0.0.1:7402", "rmit_sk_...");
/// var wallet = new Wallet(signer, chain: "base");
/// </code>
/// </example>
/// </summary>
public sealed class HttpSigner : IRemitSigner, IDisposable
{
    private readonly string _url;
    private readonly string _token;
    private readonly string _address;
    private readonly HttpClient _http;

    /// <summary>
    /// Creates an HttpSigner, fetching and caching the wallet address from
    /// the signer server synchronously.
    /// </summary>
    /// <param name="url">Signer server URL (e.g., "http://127.0.0.1:7402").</param>
    /// <param name="token">Bearer token for authentication.</param>
    /// <exception cref="RemitError">
    /// Thrown when the server is unreachable, returns an auth error, or
    /// returns a malformed response.
    /// </exception>
    public HttpSigner(string url, string token)
    {
        if (string.IsNullOrWhiteSpace(url))
            throw new RemitError(ErrorCodes.NetworkError,
                "HttpSigner: url must not be empty.");

        if (string.IsNullOrWhiteSpace(token))
            throw new RemitError(ErrorCodes.Unauthorized,
                "HttpSigner: token must not be empty.");

        _url = url.TrimEnd('/');
        _token = token;
        _http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        _http.DefaultRequestHeaders.Accept.Add(
            new MediaTypeWithQualityHeaderValue("application/json"));

        _address = FetchAddress();
    }

    /// <summary>
    /// Internal constructor for testing - accepts an HttpClient to allow mock handlers.
    /// </summary>
    internal HttpSigner(string url, string token, HttpClient httpClient)
    {
        if (string.IsNullOrWhiteSpace(url))
            throw new RemitError(ErrorCodes.NetworkError,
                "HttpSigner: url must not be empty.");

        if (string.IsNullOrWhiteSpace(token))
            throw new RemitError(ErrorCodes.Unauthorized,
                "HttpSigner: token must not be empty.");

        _url = url.TrimEnd('/');
        _token = token;
        _http = httpClient;

        _address = FetchAddress();
    }

    /// <inheritdoc />
    public string Address => _address;

    /// <inheritdoc />
    public string Sign(byte[] hash)
    {
        var hexDigest = "0x" + Convert.ToHexString(hash).ToLowerInvariant();
        var payload = JsonSerializer.Serialize(new { digest = hexDigest });
        var content = new StringContent(payload, Encoding.UTF8, "application/json");

        using var request = new HttpRequestMessage(HttpMethod.Post, $"{_url}/sign/digest");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _token);
        request.Content = content;

        HttpResponseMessage response;
        try
        {
            response = Task.Run(() => _http.SendAsync(request)).GetAwaiter().GetResult();
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or AggregateException)
        {
            var inner = ex is AggregateException agg ? agg.InnerException ?? ex : ex;
            throw new RemitError(ErrorCodes.NetworkError,
                $"HttpSigner: cannot reach signer server: {inner.Message}");
        }

        if ((int)response.StatusCode == 401)
            throw new RemitError(ErrorCodes.Unauthorized,
                "HttpSigner: unauthorized - check your REMIT_SIGNER_TOKEN");

        if ((int)response.StatusCode == 403)
        {
            var reason = ReadErrorReason(response, "unknown reason");
            throw new RemitError(ErrorCodes.Unauthorized,
                $"HttpSigner: policy denied - {reason}");
        }

        if (!response.IsSuccessStatusCode)
        {
            var detail = ReadErrorReason(response, response.ReasonPhrase ?? "unknown");
            throw new RemitError(ErrorCodes.ServerError,
                $"HttpSigner: sign failed ({(int)response.StatusCode}): {detail}",
                httpStatus: (int)response.StatusCode);
        }

        var body = ReadJson(response);
        if (body == null || !body.Value.TryGetProperty("signature", out var sigProp) ||
            sigProp.ValueKind != JsonValueKind.String)
        {
            throw new RemitError(ErrorCodes.ServerError,
                "HttpSigner: server returned no signature");
        }

        return sigProp.GetString()!;
    }

    /// <summary>Prevent token leakage in serialization/logging.</summary>
    public override string ToString() => $"HttpSigner {{ address: '{_address}' }}";

    public void Dispose() => _http.Dispose();

    // ─── Private helpers ────────────────────────────────────────────────────

    private string FetchAddress()
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"{_url}/address");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _token);

        HttpResponseMessage response;
        try
        {
            response = Task.Run(() => _http.SendAsync(request)).GetAwaiter().GetResult();
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or AggregateException)
        {
            var inner = ex is AggregateException agg ? agg.InnerException ?? ex : ex;
            throw new RemitError(ErrorCodes.NetworkError,
                $"HttpSigner: cannot reach signer server at {_url}: {inner.Message}");
        }

        if ((int)response.StatusCode == 401)
            throw new RemitError(ErrorCodes.Unauthorized,
                "HttpSigner: unauthorized - check your REMIT_SIGNER_TOKEN");

        if (!response.IsSuccessStatusCode)
        {
            var detail = ReadErrorReason(response, response.ReasonPhrase ?? "unknown");
            throw new RemitError(ErrorCodes.ServerError,
                $"HttpSigner: GET /address failed ({(int)response.StatusCode}): {detail}",
                httpStatus: (int)response.StatusCode);
        }

        var body = ReadJson(response);
        if (body == null || !body.Value.TryGetProperty("address", out var addrProp) ||
            addrProp.ValueKind != JsonValueKind.String ||
            string.IsNullOrWhiteSpace(addrProp.GetString()))
        {
            throw new RemitError(ErrorCodes.ServerError,
                "HttpSigner: GET /address returned no address");
        }

        return addrProp.GetString()!;
    }

    private static JsonElement? ReadJson(HttpResponseMessage response)
    {
        try
        {
            var text = Task.Run(() => response.Content.ReadAsStringAsync()).GetAwaiter().GetResult();
            return JsonSerializer.Deserialize<JsonElement>(text);
        }
        catch
        {
            return null;
        }
    }

    private static string ReadErrorReason(HttpResponseMessage response, string fallback)
    {
        var body = ReadJson(response);
        if (body == null) return fallback;

        if (body.Value.TryGetProperty("reason", out var reason) &&
            reason.ValueKind == JsonValueKind.String &&
            !string.IsNullOrWhiteSpace(reason.GetString()))
            return reason.GetString()!;

        if (body.Value.TryGetProperty("error", out var error) &&
            error.ValueKind == JsonValueKind.String &&
            !string.IsNullOrWhiteSpace(error.GetString()))
            return error.GetString()!;

        return fallback;
    }
}
