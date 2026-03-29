package md.remit;

import com.fasterxml.jackson.databind.ObjectMapper;
import md.remit.internal.ApiClient;
import md.remit.signer.Signer;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Base64;
import java.util.HexFormat;
import java.util.Map;

/**
 * x402 client that auto-pays HTTP 402 Payment Required responses.
 *
 * <p>On receiving a 402, the client:
 * <ol>
 *   <li>Decodes the {@code PAYMENT-REQUIRED} header (base64 JSON)</li>
 *   <li>Checks the amount is within {@code maxAutoPayUsdc}</li>
 *   <li>Calls {@code /x402/prepare} to get a signable hash and authorization fields</li>
 *   <li>Signs the hash and builds the {@code PAYMENT-SIGNATURE} header</li>
 *   <li>Retries the original request with payment attached</li>
 * </ol>
 *
 * <pre>{@code
 * Wallet wallet = RemitMd.fromEnv();
 * X402Client x402 = new X402Client(wallet, 0.10);
 * X402Client.X402Response resp = x402.fetch("https://api.provider.com/data");
 * }</pre>
 */
public class X402Client {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final Signer signer;
    private final String address;
    private final ApiClient apiClient;
    private final double maxAutoPayUsdc;
    private final HttpClient http;

    /** The last PAYMENT-REQUIRED payload decoded before payment. */
    private Map<String, Object> lastPayment;

    /** Response wrapper including the HTTP response and last payment metadata. */
    public record X402Response(HttpResponse<String> response, Map<String, Object> lastPayment) {}

    /** Raised when an x402 payment amount exceeds the configured auto-pay limit. */
    public static class AllowanceExceededError extends RuntimeException {
        public final double amountUsdc;
        public final double limitUsdc;

        public AllowanceExceededError(double amountUsdc, double limitUsdc) {
            super(String.format("x402 payment %.6f USDC exceeds auto-pay limit %.6f USDC", amountUsdc, limitUsdc));
            this.amountUsdc = amountUsdc;
            this.limitUsdc = limitUsdc;
        }
    }

    public X402Client(Wallet wallet, double maxAutoPayUsdc) {
        this.signer = wallet.signer();
        this.address = wallet.address();
        this.apiClient = wallet.apiClient();
        this.maxAutoPayUsdc = maxAutoPayUsdc;
        this.http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();
    }

    /**
     * Fetches a URL, auto-paying any 402 response within the configured limit.
     *
     * @param url the URL to fetch
     * @return response and payment metadata
     */
    @SuppressWarnings("unchecked")
    public X402Response fetch(String url) throws Exception {
        HttpRequest req = HttpRequest.newBuilder()
            .uri(URI.create(url))
            .GET()
            .timeout(Duration.ofSeconds(30))
            .build();
        HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());

        if (resp.statusCode() != 402) {
            return new X402Response(resp, null);
        }

        // Decode PAYMENT-REQUIRED header
        String raw = resp.headers().firstValue("payment-required")
            .or(() -> resp.headers().firstValue("PAYMENT-REQUIRED"))
            .orElseThrow(() -> new RuntimeException("402 response missing PAYMENT-REQUIRED header"));

        String decoded = new String(Base64.getDecoder().decode(raw), StandardCharsets.UTF_8);
        Map<String, Object> required = MAPPER.readValue(decoded, Map.class);

        String scheme = (String) required.get("scheme");
        if (!"exact".equals(scheme)) {
            throw new RuntimeException("Unsupported x402 scheme: " + scheme);
        }

        lastPayment = required;

        // Check amount against limit
        String amountStr = (String) required.get("amount");
        long amountBaseUnits = Long.parseLong(amountStr);
        double amountUsdc = amountBaseUnits / 1_000_000.0;
        if (amountUsdc > maxAutoPayUsdc) {
            throw new AllowanceExceededError(amountUsdc, maxAutoPayUsdc);
        }

        // Call /x402/prepare to get the hash + authorization fields
        Map<String, Object> prepareData = apiClient.post(
            "/api/v1/x402/prepare",
            Map.of("payment_required", decoded, "payer", address),
            Map.class);

        // Sign the hash
        String hashHex = (String) prepareData.get("hash");
        byte[] hashBytes = HexFormat.of().parseHex(hashHex.substring(2));
        String signature = signer.signHash(hashBytes);

        // Build PAYMENT-SIGNATURE JSON payload
        String network = (String) required.get("network");
        Map<String, Object> authorization = Map.of(
            "from", (String) prepareData.get("from"),
            "to", (String) prepareData.get("to"),
            "value", (String) prepareData.get("value"),
            "validAfter", (String) prepareData.get("valid_after"),
            "validBefore", (String) prepareData.get("valid_before"),
            "nonce", (String) prepareData.get("nonce")
        );
        Map<String, Object> payload = Map.of(
            "scheme", scheme,
            "network", network,
            "x402Version", 1,
            "payload", Map.of(
                "signature", signature,
                "authorization", authorization
            )
        );
        String paymentHeader = Base64.getEncoder().encodeToString(
            MAPPER.writeValueAsBytes(payload));

        // Retry with PAYMENT-SIGNATURE
        HttpRequest retryReq = HttpRequest.newBuilder()
            .uri(URI.create(url))
            .header("PAYMENT-SIGNATURE", paymentHeader)
            .GET()
            .timeout(Duration.ofSeconds(30))
            .build();
        HttpResponse<String> retryResp = http.send(retryReq, HttpResponse.BodyHandlers.ofString());
        return new X402Response(retryResp, required);
    }

    public Map<String, Object> lastPayment() {
        return lastPayment;
    }
}
