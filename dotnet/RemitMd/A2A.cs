using System.Net.Http.Json;
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
