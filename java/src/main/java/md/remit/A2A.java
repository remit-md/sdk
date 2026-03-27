package md.remit;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.ObjectMapper;
import md.remit.internal.ApiClient;
import md.remit.signer.Signer;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;

/** A2A / AP2 agent card types, discovery, and JSON-RPC task client. */
public final class A2A {

    private A2A() {}

    private static final HttpClient HTTP = HttpClient.newHttpClient();
    private static final ObjectMapper MAPPER = new ObjectMapper();

    // ─── Agent Card types ───────────────────────────────────────────────────

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

    // ─── A2A task types ─────────────────────────────────────────────────────

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record TaskStatus(
            @JsonProperty("state") String state,
            @JsonProperty("message") Map<String, Object> message
    ) {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record ArtifactPart(
            @JsonProperty("kind") String kind,
            @JsonProperty("data") Map<String, Object> data
    ) {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Artifact(
            @JsonProperty("name") String name,
            @JsonProperty("parts") List<ArtifactPart> parts
    ) {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Task(
            @JsonProperty("id") String id,
            @JsonProperty("status") TaskStatus status,
            @JsonProperty("artifacts") List<Artifact> artifacts
    ) {}

    /** Intent-based payment mandate. */
    public record IntentMandate(
            String mandateId,
            String expiresAt,
            String issuer,
            Map<String, String> allowance
    ) {}

    /** Options for {@link Client#send}. */
    public record SendOptions(
            String to,
            double amount,
            String memo,
            IntentMandate mandate
    ) {
        public SendOptions(String to, double amount) {
            this(to, amount, "", null);
        }

        public SendOptions(String to, double amount, String memo) {
            this(to, amount, memo, null);
        }
    }

    /**
     * Extract {@code txHash} from task artifacts, if present.
     *
     * @param task the A2A task
     * @return txHash string, or null if not found
     */
    public static String getTaskTxHash(Task task) {
        if (task.artifacts() == null) return null;
        for (Artifact artifact : task.artifacts()) {
            if (artifact.parts() == null) continue;
            for (ArtifactPart part : artifact.parts()) {
                if (part.data() != null && part.data().containsKey("txHash")) {
                    Object tx = part.data().get("txHash");
                    if (tx instanceof String) return (String) tx;
                }
            }
        }
        return null;
    }

    // ─── A2A JSON-RPC client ────────────────────────────────────────────────

    /**
     * A2A JSON-RPC client - send payments and manage tasks via the A2A protocol.
     *
     * <pre>{@code
     * AgentCard card = AgentCard.discover("https://remit.md").join();
     * PrivateKeySigner signer = new PrivateKeySigner("0x...");
     * A2A.Client client = A2A.Client.fromCard(card, signer);
     * A2A.Task task = client.send(new A2A.SendOptions("0xRecipient...", 10));
     * String txHash = A2A.getTaskTxHash(task);
     * }</pre>
     */
    public static class Client {

        private final ApiClient http;
        private final String path;

        /**
         * Creates a new A2A client.
         *
         * @param endpoint           full A2A endpoint URL (e.g. "https://remit.md/a2a")
         * @param signer             EIP-712 signer
         * @param chainId            chain ID (e.g. 8453)
         * @param verifyingContract  EIP-712 verifying contract address (optional)
         */
        public Client(String endpoint, Signer signer, long chainId, String verifyingContract) {
            URI parsed = URI.create(endpoint);
            String baseUrl = parsed.getScheme() + "://" + parsed.getAuthority();
            this.path = parsed.getPath() != null && !parsed.getPath().isEmpty()
                ? parsed.getPath() : "/a2a";
            this.http = new ApiClient(baseUrl, chainId,
                verifyingContract != null ? verifyingContract : "", signer);
        }

        /** Convenience constructor from an {@link AgentCard} and a signer. */
        public static Client fromCard(AgentCard card, Signer signer) {
            return fromCard(card, signer, 8453L, "");
        }

        /** Convenience constructor from an {@link AgentCard}, signer, and chain config. */
        public static Client fromCard(AgentCard card, Signer signer, long chainId, String verifyingContract) {
            return new Client(card.url(), signer, chainId, verifyingContract);
        }

        /**
         * Send a direct USDC payment via {@code message/send}.
         *
         * @param opts send options (to, amount, memo, mandate)
         * @return Task with status.state == "completed" on success
         */
        public Task send(SendOptions opts) {
            String nonce = UUID.randomUUID().toString().replace("-", "");
            String messageId = UUID.randomUUID().toString().replace("-", "");

            Map<String, Object> data = new LinkedHashMap<>();
            data.put("model", "direct");
            data.put("to", opts.to());
            data.put("amount", String.format("%.2f", opts.amount()));
            data.put("memo", opts.memo() != null ? opts.memo() : "");
            data.put("nonce", nonce);

            Map<String, Object> part = Map.of("kind", "data", "data", data);
            Map<String, Object> message = new LinkedHashMap<>();
            message.put("messageId", messageId);
            message.put("role", "user");
            message.put("parts", List.of(part));

            if (opts.mandate() != null) {
                message.put("metadata", Map.of("mandate", opts.mandate()));
            }

            return rpc("message/send", Map.of("message", message), messageId);
        }

        /** Fetch the current state of an A2A task by ID. */
        public Task getTask(String taskId) {
            return rpc("tasks/get", Map.of("id", taskId), taskId.substring(0, Math.min(16, taskId.length())));
        }

        /** Cancel an in-progress A2A task. */
        public Task cancelTask(String taskId) {
            return rpc("tasks/cancel", Map.of("id", taskId), taskId.substring(0, Math.min(16, taskId.length())));
        }

        @SuppressWarnings("unchecked")
        private Task rpc(String method, Object params, String callId) {
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("jsonrpc", "2.0");
            body.put("id", callId);
            body.put("method", method);
            body.put("params", params);

            Map<String, Object> resp = http.post(path, body, Map.class);
            if (resp == null) {
                throw new RuntimeException("A2A error: null response");
            }
            if (resp.containsKey("error")) {
                Object err = resp.get("error");
                String msg = err instanceof Map ? String.valueOf(((Map<?, ?>) err).get("message")) : String.valueOf(err);
                throw new RuntimeException("A2A error: " + msg);
            }

            Object result = resp.containsKey("result") ? resp.get("result") : resp;
            try {
                String json = MAPPER.writeValueAsString(result);
                return MAPPER.readValue(json, Task.class);
            } catch (Exception e) {
                throw new RuntimeException("Failed to parse A2A task response", e);
            }
        }
    }
}
