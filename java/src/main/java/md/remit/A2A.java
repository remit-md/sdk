package md.remit;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;

/** A2A / AP2 agent card types and discovery. */
public final class A2A {

    private A2A() {}

    private static final HttpClient HTTP = HttpClient.newHttpClient();
    private static final ObjectMapper MAPPER = new ObjectMapper();

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Extension(
            @JsonProperty("uri") String uri,
            @JsonProperty("description") String description,
            @JsonProperty("required") boolean required
    ) {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Capabilities(
            @JsonProperty("streaming") boolean streaming,
            @JsonProperty("pushNotifications") boolean pushNotifications,
            @JsonProperty("stateTransitionHistory") boolean stateTransitionHistory,
            @JsonProperty("extensions") List<Extension> extensions
    ) {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Skill(
            @JsonProperty("id") String id,
            @JsonProperty("name") String name,
            @JsonProperty("description") String description,
            @JsonProperty("tags") List<String> tags
    ) {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Fees(
            @JsonProperty("standardBps") int standardBps,
            @JsonProperty("preferredBps") int preferredBps,
            @JsonProperty("cliffUsd") int cliffUsd
    ) {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record X402(
            @JsonProperty("settleEndpoint") String settleEndpoint,
            @JsonProperty("assets") Map<String, String> assets,
            @JsonProperty("fees") Fees fees
    ) {}

    /**
     * A2A agent card parsed from {@code /.well-known/agent-card.json}.
     */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public record AgentCard(
            @JsonProperty("protocolVersion") String protocolVersion,
            @JsonProperty("name") String name,
            @JsonProperty("description") String description,
            @JsonProperty("url") String url,
            @JsonProperty("version") String version,
            @JsonProperty("documentationUrl") String documentationUrl,
            @JsonProperty("capabilities") Capabilities capabilities,
            @JsonProperty("skills") List<Skill> skills,
            @JsonProperty("x402") X402 x402
    ) {
        /**
         * Fetch and parse the A2A agent card from
         * {@code baseUrl/.well-known/agent-card.json}.
         *
         * @param baseUrl Root URL of the agent (e.g. {@code https://remit.md}).
         * @return CompletableFuture resolving to the parsed {@link AgentCard}.
         */
        public static CompletableFuture<AgentCard> discover(String baseUrl) {
            String url = baseUrl.stripTrailing().replaceAll("/$", "")
                    + "/.well-known/agent-card.json";
            HttpRequest req = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .header("Accept", "application/json")
                    .GET()
                    .build();
            return HTTP.sendAsync(req, HttpResponse.BodyHandlers.ofString())
                    .thenApply(resp -> {
                        if (resp.statusCode() != 200) {
                            throw new RuntimeException(
                                    "Agent card discovery failed: HTTP " + resp.statusCode());
                        }
                        try {
                            return MAPPER.readValue(resp.body(), AgentCard.class);
                        } catch (Exception e) {
                            throw new RuntimeException("Failed to parse agent card", e);
                        }
                    });
        }
    }
}
