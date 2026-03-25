package md.remit;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * x402 paywall for service providers — gate HTTP endpoints behind USDC payments.
 *
 * <p>Providers use this class to:
 * <ul>
 *   <li>Return HTTP 402 responses with properly formatted {@code PAYMENT-REQUIRED} headers</li>
 *   <li>Verify incoming {@code PAYMENT-SIGNATURE} headers against the remit.md facilitator</li>
 * </ul>
 *
 * <pre>{@code
 * X402Paywall paywall = new X402Paywall(
 *     "0xYourProviderWallet",
 *     0.001,
 *     "eip155:84532",
 *     "0x2d846325766921935f37d5b4478196d3ef93707c",
 *     null, null, 60
 * );
 *
 * // In a servlet filter or handler:
 * String header = paywall.paymentRequiredHeader();
 * X402Paywall.CheckResult result = paywall.check(paymentSig);
 * }</pre>
 */
public class X402Paywall {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final HttpClient HTTP = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(10))
        .build();

    private final String walletAddress;
    private final String amountBaseUnits;
    private final String network;
    private final String asset;
    private final String facilitatorUrl;
    private final String facilitatorToken;
    private final int maxTimeoutSeconds;
    private final String resource;
    private final String description;
    private final String mimeType;

    /** Result of {@link #check(String)}. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class CheckResult {
        @JsonProperty("isValid")
        public boolean isValid;

        @JsonProperty("invalidReason")
        public String invalidReason;

        public CheckResult() {}

        public CheckResult(boolean isValid, String invalidReason) {
            this.isValid = isValid;
            this.invalidReason = invalidReason;
        }
    }

    /**
     * Creates a new X402Paywall.
     *
     * @param walletAddress      provider's checksummed Ethereum address (the payTo field)
     * @param amountUsdc         price per request in USDC (e.g. 0.001)
     * @param network            CAIP-2 network string (e.g. "eip155:84532")
     * @param asset              USDC contract address on the target network
     * @param facilitatorUrl     base URL of the facilitator (default: "https://remit.md")
     * @param facilitatorToken   bearer JWT for authenticating with the facilitator (optional)
     * @param maxTimeoutSeconds  how long the payment authorization remains valid (default: 60)
     */
    public X402Paywall(
            String walletAddress,
            double amountUsdc,
            String network,
            String asset,
            String facilitatorUrl,
            String facilitatorToken,
            int maxTimeoutSeconds) {
        this(walletAddress, amountUsdc, network, asset, facilitatorUrl, facilitatorToken,
             maxTimeoutSeconds, null, null, null);
    }

    /**
     * Creates a new X402Paywall with V2 fields.
     *
     * @param walletAddress      provider's checksummed Ethereum address
     * @param amountUsdc         price per request in USDC
     * @param network            CAIP-2 network string
     * @param asset              USDC contract address
     * @param facilitatorUrl     base URL of the facilitator (null for default)
     * @param facilitatorToken   bearer JWT (optional)
     * @param maxTimeoutSeconds  payment authorization validity in seconds
     * @param resource           V2: URL or path of the protected resource
     * @param description        V2: human-readable description
     * @param mimeType           V2: MIME type of the resource
     */
    public X402Paywall(
            String walletAddress,
            double amountUsdc,
            String network,
            String asset,
            String facilitatorUrl,
            String facilitatorToken,
            int maxTimeoutSeconds,
            String resource,
            String description,
            String mimeType) {
        this.walletAddress = walletAddress;
        this.amountBaseUnits = String.valueOf(Math.round(amountUsdc * 1_000_000));
        this.network = network;
        this.asset = asset;
        this.facilitatorUrl = (facilitatorUrl != null ? facilitatorUrl : "https://remit.md")
            .replaceAll("/$", "");
        this.facilitatorToken = facilitatorToken != null ? facilitatorToken : "";
        this.maxTimeoutSeconds = maxTimeoutSeconds > 0 ? maxTimeoutSeconds : 60;
        this.resource = resource;
        this.description = description;
        this.mimeType = mimeType;
    }

    /** Returns the base64-encoded JSON {@code PAYMENT-REQUIRED} header value. */
    public String paymentRequiredHeader() {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("scheme", "exact");
        payload.put("network", network);
        payload.put("amount", amountBaseUnits);
        payload.put("asset", asset);
        payload.put("payTo", walletAddress);
        payload.put("maxTimeoutSeconds", maxTimeoutSeconds);
        if (resource != null) payload.put("resource", resource);
        if (description != null) payload.put("description", description);
        if (mimeType != null) payload.put("mimeType", mimeType);
        try {
            byte[] json = MAPPER.writeValueAsBytes(payload);
            return Base64.getEncoder().encodeToString(json);
        } catch (Exception e) {
            throw new RuntimeException("Failed to encode payment-required header", e);
        }
    }

    /**
     * Check whether a {@code PAYMENT-SIGNATURE} header represents a valid payment.
     *
     * <p>Calls the facilitator's {@code /api/v1/x402/verify} endpoint.
     *
     * @param paymentSig the raw header value (base64 JSON), or null if absent
     * @return {@link CheckResult} with isValid and optional invalidReason
     */
    @SuppressWarnings("unchecked")
    public CheckResult check(String paymentSig) {
        if (paymentSig == null || paymentSig.isBlank()) {
            return new CheckResult(false, null);
        }

        Object paymentPayload;
        try {
            String decoded = new String(Base64.getDecoder().decode(paymentSig), StandardCharsets.UTF_8);
            paymentPayload = MAPPER.readValue(decoded, Object.class);
        } catch (Exception e) {
            return new CheckResult(false, "INVALID_PAYLOAD");
        }

        Map<String, Object> paymentRequired = new LinkedHashMap<>();
        paymentRequired.put("scheme", "exact");
        paymentRequired.put("network", network);
        paymentRequired.put("amount", amountBaseUnits);
        paymentRequired.put("asset", asset);
        paymentRequired.put("payTo", walletAddress);
        paymentRequired.put("maxTimeoutSeconds", maxTimeoutSeconds);

        Map<String, Object> body = Map.of(
            "paymentPayload", paymentPayload,
            "paymentRequired", paymentRequired
        );

        try {
            byte[] bodyJson = MAPPER.writeValueAsBytes(body);
            HttpRequest.Builder builder = HttpRequest.newBuilder()
                .uri(URI.create(facilitatorUrl + "/api/v1/x402/verify"))
                .header("Content-Type", "application/json")
                .timeout(Duration.ofSeconds(15))
                .POST(HttpRequest.BodyPublishers.ofByteArray(bodyJson));

            if (!facilitatorToken.isEmpty()) {
                builder.header("Authorization", "Bearer " + facilitatorToken);
            }

            HttpResponse<String> resp = HTTP.send(builder.build(), HttpResponse.BodyHandlers.ofString());
            if (resp.statusCode() < 200 || resp.statusCode() >= 300) {
                return new CheckResult(false, "FACILITATOR_ERROR");
            }

            Map<String, Object> data = MAPPER.readValue(resp.body(), Map.class);
            boolean isValid = Boolean.TRUE.equals(data.get("isValid"));
            String reason = data.containsKey("invalidReason") ? String.valueOf(data.get("invalidReason")) : null;
            return new CheckResult(isValid, reason);
        } catch (Exception e) {
            return new CheckResult(false, "FACILITATOR_ERROR");
        }
    }
}
