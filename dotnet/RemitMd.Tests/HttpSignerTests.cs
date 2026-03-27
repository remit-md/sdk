using System.Net;
using System.Text;
using System.Text.Json;
using RemitMd;
using Xunit;

namespace RemitMd.Tests;

/// <summary>
/// Unit tests for the <see cref="HttpSigner"/> class.
/// Uses a mock HttpMessageHandler to simulate the local signer server.
/// </summary>
public sealed class HttpSignerTests
{
    private const string MockAddress = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    private const string MockSignature = "0x" +
        "abababababababababababababababababababababababababababababababab" + // 32 bytes r
        "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd" + // 32 bytes s
        "1b";                                                               // 1 byte v
    private const string ValidToken = "rmit_sk_test_token_1234567890";
    private const string BaseUrl = "http://127.0.0.1:7402";

    // ─── Happy path ─────────────────────────────────────────────────────────

    [Fact]
    public void Create_FetchesAndCachesAddress()
    {
        var handler = new MockHandler();
        handler.SetGetAddress(HttpStatusCode.OK, new { address = MockAddress });

        var http = new HttpClient(handler);
        var signer = new HttpSigner(BaseUrl, ValidToken, http);

        Assert.Equal(MockAddress, signer.Address);
    }

    [Fact]
    public void Sign_ReturnsSignatureFromServer()
    {
        var handler = new MockHandler();
        handler.SetGetAddress(HttpStatusCode.OK, new { address = MockAddress });
        handler.SetPostSign(HttpStatusCode.OK, new { signature = MockSignature });

        var http = new HttpClient(handler);
        var signer = new HttpSigner(BaseUrl, ValidToken, http);

        var hash = new byte[32];
        Array.Fill(hash, (byte)0xAB);

        var sig = signer.Sign(hash);
        Assert.Equal(MockSignature, sig);
    }

    [Fact]
    public void Sign_SendsCorrectDigestFormat()
    {
        var handler = new MockHandler();
        handler.SetGetAddress(HttpStatusCode.OK, new { address = MockAddress });
        handler.SetPostSign(HttpStatusCode.OK, new { signature = MockSignature });

        var http = new HttpClient(handler);
        var signer = new HttpSigner(BaseUrl, ValidToken, http);

        var hash = new byte[] { 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                                 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
                                 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
                                 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20 };

        signer.Sign(hash);

        // Verify the POST body contains the correctly formatted digest
        Assert.NotNull(handler.LastPostBody);
        var body = JsonSerializer.Deserialize<JsonElement>(handler.LastPostBody!);
        Assert.True(body.TryGetProperty("digest", out var digestProp));
        Assert.Equal("0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
            digestProp.GetString());
    }

    [Fact]
    public void Sign_SendsBearerToken()
    {
        var handler = new MockHandler();
        handler.SetGetAddress(HttpStatusCode.OK, new { address = MockAddress });
        handler.SetPostSign(HttpStatusCode.OK, new { signature = MockSignature });

        var http = new HttpClient(handler);
        var signer = new HttpSigner(BaseUrl, ValidToken, http);
        signer.Sign(new byte[32]);

        // The handler checks auth automatically; also verify it was set
        Assert.NotNull(handler.LastAuthHeader);
        Assert.Equal($"Bearer {ValidToken}", handler.LastAuthHeader);
    }

    // ─── Server unreachable ─────────────────────────────────────────────────

    [Fact]
    public void Create_ServerUnreachable_ThrowsRemitError()
    {
        var handler = new MockHandler();
        handler.SetThrowOnSend(new HttpRequestException("Connection refused"));

        var http = new HttpClient(handler);
        var ex = Assert.Throws<RemitError>(() => new HttpSigner(BaseUrl, ValidToken, http));

        Assert.Equal(ErrorCodes.NetworkError, ex.Code);
        Assert.Contains("cannot reach", ex.Message);
    }

    // ─── 401 response ───────────────────────────────────────────────────────

    [Fact]
    public void Create_Unauthorized_ThrowsRemitError()
    {
        var handler = new MockHandler();
        handler.SetGetAddress(HttpStatusCode.Unauthorized, new { error = "unauthorized" });

        var http = new HttpClient(handler);
        var ex = Assert.Throws<RemitError>(() => new HttpSigner(BaseUrl, ValidToken, http));

        Assert.Equal(ErrorCodes.Unauthorized, ex.Code);
        Assert.Contains("unauthorized", ex.Message);
    }

    [Fact]
    public void Sign_Unauthorized_ThrowsRemitError()
    {
        var handler = new MockHandler();
        handler.SetGetAddress(HttpStatusCode.OK, new { address = MockAddress });
        handler.SetPostSign(HttpStatusCode.Unauthorized, new { error = "unauthorized" });

        var http = new HttpClient(handler);
        var signer = new HttpSigner(BaseUrl, ValidToken, http);

        var ex = Assert.Throws<RemitError>(() => signer.Sign(new byte[32]));

        Assert.Equal(ErrorCodes.Unauthorized, ex.Code);
        Assert.Contains("unauthorized", ex.Message);
    }

    // ─── 403 response ───────────────────────────────────────────────────────

    [Fact]
    public void Sign_PolicyDenied_ThrowsWithReason()
    {
        var handler = new MockHandler();
        handler.SetGetAddress(HttpStatusCode.OK, new { address = MockAddress });
        handler.SetPostSign(HttpStatusCode.Forbidden,
            new { error = "policy_denied", reason = "chain not allowed" });

        var http = new HttpClient(handler);
        var signer = new HttpSigner(BaseUrl, ValidToken, http);

        var ex = Assert.Throws<RemitError>(() => signer.Sign(new byte[32]));

        Assert.Equal(ErrorCodes.Unauthorized, ex.Code);
        Assert.Contains("policy denied", ex.Message);
        Assert.Contains("chain not allowed", ex.Message);
    }

    // ─── 500 response ───────────────────────────────────────────────────────

    [Fact]
    public void Create_ServerError_ThrowsRemitError()
    {
        var handler = new MockHandler();
        handler.SetGetAddress(HttpStatusCode.InternalServerError,
            new { error = "internal_error" });

        var http = new HttpClient(handler);
        var ex = Assert.Throws<RemitError>(() => new HttpSigner(BaseUrl, ValidToken, http));

        Assert.Equal(ErrorCodes.ServerError, ex.Code);
        Assert.Contains("500", ex.Message);
    }

    [Fact]
    public void Sign_ServerError_ThrowsRemitError()
    {
        var handler = new MockHandler();
        handler.SetGetAddress(HttpStatusCode.OK, new { address = MockAddress });
        handler.SetPostSign(HttpStatusCode.InternalServerError,
            new { error = "internal_error" });

        var http = new HttpClient(handler);
        var signer = new HttpSigner(BaseUrl, ValidToken, http);

        var ex = Assert.Throws<RemitError>(() => signer.Sign(new byte[32]));

        Assert.Equal(ErrorCodes.ServerError, ex.Code);
        Assert.Contains("500", ex.Message);
    }

    // ─── Malformed response ─────────────────────────────────────────────────

    [Fact]
    public void Create_MalformedResponse_ThrowsRemitError()
    {
        var handler = new MockHandler();
        handler.SetGetAddress(HttpStatusCode.OK, new { notAddress = true });

        var http = new HttpClient(handler);
        var ex = Assert.Throws<RemitError>(() => new HttpSigner(BaseUrl, ValidToken, http));

        Assert.Equal(ErrorCodes.ServerError, ex.Code);
        Assert.Contains("no address", ex.Message);
    }

    [Fact]
    public void Sign_MalformedResponse_ThrowsRemitError()
    {
        var handler = new MockHandler();
        handler.SetGetAddress(HttpStatusCode.OK, new { address = MockAddress });
        handler.SetPostSign(HttpStatusCode.OK, new { notSignature = true });

        var http = new HttpClient(handler);
        var signer = new HttpSigner(BaseUrl, ValidToken, http);

        var ex = Assert.Throws<RemitError>(() => signer.Sign(new byte[32]));

        Assert.Equal(ErrorCodes.ServerError, ex.Code);
        Assert.Contains("no signature", ex.Message);
    }

    // ─── Token safety ───────────────────────────────────────────────────────

    [Fact]
    public void ToString_DoesNotLeakToken()
    {
        var handler = new MockHandler();
        handler.SetGetAddress(HttpStatusCode.OK, new { address = MockAddress });

        var http = new HttpClient(handler);
        var signer = new HttpSigner(BaseUrl, ValidToken, http);

        var str = signer.ToString();
        Assert.DoesNotContain(ValidToken, str);
        Assert.Contains(MockAddress, str);
    }

    // ─── Input validation ───────────────────────────────────────────────────

    [Fact]
    public void Create_EmptyUrl_ThrowsRemitError()
    {
        var ex = Assert.Throws<RemitError>(() => new HttpSigner("", ValidToken));
        Assert.Equal(ErrorCodes.NetworkError, ex.Code);
    }

    [Fact]
    public void Create_EmptyToken_ThrowsRemitError()
    {
        var ex = Assert.Throws<RemitError>(() => new HttpSigner(BaseUrl, ""));
        Assert.Equal(ErrorCodes.Unauthorized, ex.Code);
    }

    // ─── Mock HttpMessageHandler ────────────────────────────────────────────

    private sealed class MockHandler : HttpMessageHandler
    {
        private HttpStatusCode _getAddressStatus = HttpStatusCode.OK;
        private string _getAddressBody = "{}";
        private HttpStatusCode _postSignStatus = HttpStatusCode.OK;
        private string _postSignBody = "{}";
        private Exception? _throwOnSend;

        public string? LastPostBody { get; private set; }
        public string? LastAuthHeader { get; private set; }

        public void SetGetAddress(HttpStatusCode status, object body)
        {
            _getAddressStatus = status;
            _getAddressBody = JsonSerializer.Serialize(body);
        }

        public void SetPostSign(HttpStatusCode status, object body)
        {
            _postSignStatus = status;
            _postSignBody = JsonSerializer.Serialize(body);
        }

        public void SetThrowOnSend(Exception ex)
        {
            _throwOnSend = ex;
        }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (_throwOnSend != null)
                throw _throwOnSend;

            LastAuthHeader = request.Headers.Authorization?.ToString();

            var path = request.RequestUri?.AbsolutePath ?? "";

            if (request.Method == HttpMethod.Get && path == "/address")
            {
                return Task.FromResult(new HttpResponseMessage(_getAddressStatus)
                {
                    Content = new StringContent(_getAddressBody, Encoding.UTF8, "application/json"),
                });
            }

            if (request.Method == HttpMethod.Post && path == "/sign/digest")
            {
                LastPostBody = request.Content?.ReadAsStringAsync().GetAwaiter().GetResult();
                return Task.FromResult(new HttpResponseMessage(_postSignStatus)
                {
                    Content = new StringContent(_postSignBody, Encoding.UTF8, "application/json"),
                });
            }

            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound)
            {
                Content = new StringContent("{\"error\":\"not_found\"}", Encoding.UTF8, "application/json"),
            });
        }
    }
}
