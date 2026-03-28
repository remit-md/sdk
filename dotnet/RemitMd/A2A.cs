using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RemitMd;

/// <summary>A2A capability extension declared in an agent card.</summary>
public record A2AExtension(
    [property: JsonPropertyName("uri")] string Uri,
    [property: JsonPropertyName("description")] string Description,
    [property: JsonPropertyName("required")] bool Required
);

/// <summary>Capabilities block from an A2A agent card.</summary>
public record A2ACapabilities(
    [property: JsonPropertyName("streaming")] bool Streaming,
    [property: JsonPropertyName("pushNotifications")] bool PushNotifications,
    [property: JsonPropertyName("stateTransitionHistory")] bool StateTransitionHistory,
    [property: JsonPropertyName("extensions")] List<A2AExtension> Extensions
);

/// <summary>A single skill declared in an A2A agent card.</summary>
public record A2ASkill(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("description")] string Description,
    [property: JsonPropertyName("tags")] List<string> Tags
);

/// <summary>Fee info block inside the x402 capability.</summary>
public record A2AFees(
    [property: JsonPropertyName("standardBps")] int StandardBps,
    [property: JsonPropertyName("preferredBps")] int PreferredBps,
    [property: JsonPropertyName("cliffUsd")] int CliffUsd
);

/// <summary>x402 payment capability block in an agent card.</summary>
public record A2AX402(
    [property: JsonPropertyName("settleEndpoint")] string SettleEndpoint,
    [property: JsonPropertyName("assets")] Dictionary<string, string> Assets,
    [property: JsonPropertyName("fees")] A2AFees Fees
);

/// <summary>
/// A2A agent card parsed from <c>/.well-known/agent-card.json</c>.
/// </summary>
public record AgentCard(
    [property: JsonPropertyName("protocolVersion")] string ProtocolVersion,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("description")] string Description,
    [property: JsonPropertyName("url")] string Url,
    [property: JsonPropertyName("version")] string Version,
    [property: JsonPropertyName("documentationUrl")] string DocumentationUrl,
    [property: JsonPropertyName("capabilities")] A2ACapabilities Capabilities,
    [property: JsonPropertyName("skills")] List<A2ASkill> Skills,
    [property: JsonPropertyName("x402")] A2AX402 X402
)
{
    private static readonly HttpClient _http = new();

    /// <summary>
    /// Fetch and parse the A2A agent card from
    /// <c>baseUrl/.well-known/agent-card.json</c>.
    /// </summary>
    /// <param name="baseUrl">Root URL of the agent (e.g. <c>https://remit.md</c>).</param>
    /// <param name="cancellationToken">Optional cancellation token.</param>
    public static async Task<AgentCard> DiscoverAsync(
        string baseUrl,
        CancellationToken cancellationToken = default)
    {
        var url = baseUrl.TrimEnd('/') + "/.well-known/agent-card.json";
        var card = await _http.GetFromJsonAsync<AgentCard>(
            url,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true },
            cancellationToken
        ) ?? throw new InvalidOperationException("Agent card response was empty.");
        return card;
    }
}

// ─── A2A task types ───────────────────────────────────────────────────────────

/// <summary>Status of an A2A task.</summary>
public sealed class A2ATaskStatus
{
    [JsonPropertyName("state")] public string State { get; set; } = "";
    [JsonPropertyName("message")] public A2AMessage? Message { get; set; }
}

/// <summary>Message within an A2A task status.</summary>
public sealed class A2AMessage
{
    [JsonPropertyName("text")] public string? Text { get; set; }
}

/// <summary>Part of an A2A artifact.</summary>
public sealed class A2AArtifactPart
{
    [JsonPropertyName("kind")] public string Kind { get; set; } = "";
    [JsonPropertyName("data")] public Dictionary<string, object>? Data { get; set; }
}

/// <summary>Artifact produced by an A2A task.</summary>
public sealed class A2AArtifact
{
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("parts")] public List<A2AArtifactPart> Parts { get; set; } = new();
}

/// <summary>An A2A task.</summary>
public sealed class A2ATask
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("status")] public A2ATaskStatus Status { get; set; } = new();
    [JsonPropertyName("artifacts")] public List<A2AArtifact> Artifacts { get; set; } = new();

    /// <summary>Extract txHash from task artifacts, if present.</summary>
    public string? GetTxHash()
    {
        foreach (var artifact in Artifacts)
            foreach (var part in artifact.Parts)
                if (part.Data?.TryGetValue("txHash", out var tx) == true && tx is JsonElement je && je.ValueKind == JsonValueKind.String)
                    return je.GetString();
        return null;
    }
}

// ─── IntentMandate ────────────────────────────────────────────────────────────

/// <summary>An intent mandate for authorized payment delegation.</summary>
public record IntentMandate(
    [property: JsonPropertyName("mandateId")] string MandateId,
    [property: JsonPropertyName("expiresAt")] string ExpiresAt,
    [property: JsonPropertyName("issuer")] string Issuer,
    [property: JsonPropertyName("allowance")] IntentMandateAllowance Allowance
);

/// <summary>Allowance within an IntentMandate.</summary>
public record IntentMandateAllowance(
    [property: JsonPropertyName("maxAmount")] string MaxAmount,
    [property: JsonPropertyName("currency")] string Currency
);

// ─── A2A client ───────────────────────────────────────────────────────────────

/// <summary>Options for the A2A client.</summary>
public sealed class A2AClientOptions
{
    /// <summary>Full A2A endpoint URL from the agent card (e.g. "https://remit.md/a2a").</summary>
    public string Endpoint { get; set; } = "";
    /// <summary>Signer used for EIP-712 request authentication.</summary>
    public IRemitSigner Signer { get; set; } = null!;
    /// <summary>Chain ID for EIP-712 domain.</summary>
    public long ChainId { get; set; } = 8453;
    /// <summary>EIP-712 verifying contract address.</summary>
    public string VerifyingContract { get; set; } = "";
}

/// <summary>
/// A2A JSON-RPC client - send payments and manage tasks via the A2A protocol.
/// </summary>
public sealed class A2AClient : IDisposable
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private static readonly Dictionary<string, long> ChainIds = new()
    {
        ["base"] = 8453,
        ["base-sepolia"] = 84532,
    };

    private readonly ApiClient _api;
    private readonly string _path;

    /// <summary>Creates an A2A client from explicit options.</summary>
    public A2AClient(A2AClientOptions opts)
    {
        var parsed = new Uri(opts.Endpoint);
        var baseUrl = $"{parsed.Scheme}://{parsed.Host}" +
            (parsed.IsDefaultPort ? "" : $":{parsed.Port}");
        _path = string.IsNullOrEmpty(parsed.AbsolutePath) || parsed.AbsolutePath == "/"
            ? "/a2a" : parsed.AbsolutePath;
        _api = new ApiClient(opts.Signer, opts.ChainId, opts.VerifyingContract, baseUrl);
    }

    /// <summary>Convenience constructor from an AgentCard and a signer.</summary>
    public static A2AClient FromCard(AgentCard card, IRemitSigner signer, string chain = "base", string verifyingContract = "")
    {
        var chainId = ChainIds.TryGetValue(chain, out var cid) ? cid : 8453;
        return new A2AClient(new A2AClientOptions
        {
            Endpoint = card.Url,
            Signer = signer,
            ChainId = chainId,
            VerifyingContract = verifyingContract,
        });
    }

    /// <summary>
    /// Send a direct USDC payment via <c>message/send</c>.
    /// </summary>
    public Task<A2ATask> SendAsync(string to, decimal amount, string memo = "", IntentMandate? mandate = null, PermitSignature? permit = null, CancellationToken ct = default)
    {
        var nonce = Guid.NewGuid().ToString("N");
        var messageId = Guid.NewGuid().ToString("N");

        var data = new Dictionary<string, object>
        {
            ["model"] = "direct",
            ["to"] = to,
            ["amount"] = amount.ToString("F2"),
            ["memo"] = memo,
            ["nonce"] = nonce,
        };

        if (permit is not null)
            data["permit"] = permit;

        var message = new Dictionary<string, object>
        {
            ["messageId"] = messageId,
            ["role"] = "user",
            ["parts"] = new object[]
            {
                new Dictionary<string, object>
                {
                    ["kind"] = "data",
                    ["data"] = data,
                },
            },
        };

        if (mandate is not null)
            message["metadata"] = new Dictionary<string, object> { ["mandate"] = mandate };

        return RpcAsync<A2ATask>("message/send", new { message }, messageId, ct);
    }

    /// <summary>Fetch the current state of an A2A task by ID.</summary>
    public Task<A2ATask> GetTaskAsync(string taskId, CancellationToken ct = default) =>
        RpcAsync<A2ATask>("tasks/get", new { id = taskId }, taskId[..Math.Min(16, taskId.Length)], ct);

    /// <summary>Cancel an in-progress A2A task.</summary>
    public Task<A2ATask> CancelTaskAsync(string taskId, CancellationToken ct = default) =>
        RpcAsync<A2ATask>("tasks/cancel", new { id = taskId }, taskId[..Math.Min(16, taskId.Length)], ct);

    private async Task<T> RpcAsync<T>(string method, object @params, string callId, CancellationToken ct)
    {
        var body = new { jsonrpc = "2.0", id = callId, method, @params };
        var response = await _api.PostAsync<JsonElement>(_path, body, ct);

        if (response.TryGetProperty("error", out var error))
        {
            var errMsg = error.TryGetProperty("message", out var m) ? m.GetString() : JsonSerializer.Serialize(error);
            throw new RemitError(ErrorCodes.ServerError, $"A2A error: {errMsg}");
        }

        if (response.TryGetProperty("result", out var result))
            return JsonSerializer.Deserialize<T>(result.GetRawText(), JsonOpts)!;

        return JsonSerializer.Deserialize<T>(response.GetRawText(), JsonOpts)!;
    }

    public void Dispose() => _api.Dispose();
}
