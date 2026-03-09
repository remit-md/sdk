package md.remit.internal;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import md.remit.ErrorCodes;
import md.remit.RemitError;
import md.remit.signer.Signer;

import java.io.IOException;
import java.math.BigInteger;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Map;

/**
 * Internal HTTP client. Not part of the public API.
 */
public class ApiClient {

    private static final ObjectMapper MAPPER = new ObjectMapper()
        .registerModule(new JavaTimeModule())
        .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);

    private static final int MAX_RETRIES = 3;
    private static final long[] BACKOFF_MS = {500, 1_000, 2_000};

    private final HttpClient http;
    private final String baseUrl;
    private final long chainId;
    private final Signer signer;

    public ApiClient(String baseUrl, long chainId, Signer signer) {
        this.baseUrl = baseUrl.endsWith("/") ? baseUrl.substring(0, baseUrl.length() - 1) : baseUrl;
        this.chainId = chainId;
        this.signer = signer;
        this.http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();
    }

    public <T> T get(String path, Class<T> responseType) {
        return executeWithRetry(() -> doGet(path, responseType));
    }

    public <T> T post(String path, Object body, Class<T> responseType) {
        return executeWithRetry(() -> doPost(path, body, responseType));
    }

    private <T> T doGet(String path, Class<T> responseType) throws Exception {
        String nonce = generateNonce();
        String timestamp = Instant.now().toString();
        String signature = signRequest("GET", path, "", nonce, timestamp);

        HttpRequest req = HttpRequest.newBuilder()
            .uri(URI.create(baseUrl + path))
            .header("Content-Type", "application/json")
            .header("X-Remit-Nonce", nonce)
            .header("X-Remit-Timestamp", timestamp)
            .header("X-Remit-Signature", signature)
            .header("X-Remit-Chain", String.valueOf(chainId))
            .timeout(Duration.ofSeconds(30))
            .GET()
            .build();

        HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
        return handleResponse(resp, responseType);
    }

    private <T> T doPost(String path, Object body, Class<T> responseType) throws Exception {
        String bodyJson = body != null ? MAPPER.writeValueAsString(body) : "{}";
        String nonce = generateNonce();
        String timestamp = Instant.now().toString();
        String signature = signRequest("POST", path, bodyJson, nonce, timestamp);

        HttpRequest req = HttpRequest.newBuilder()
            .uri(URI.create(baseUrl + path))
            .header("Content-Type", "application/json")
            .header("X-Remit-Nonce", nonce)
            .header("X-Remit-Timestamp", timestamp)
            .header("X-Remit-Signature", signature)
            .header("X-Remit-Chain", String.valueOf(chainId))
            .timeout(Duration.ofSeconds(30))
            .POST(HttpRequest.BodyPublishers.ofString(bodyJson))
            .build();

        HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
        return handleResponse(resp, responseType);
    }

    private <T> T handleResponse(HttpResponse<String> resp, Class<T> responseType) throws Exception {
        int status = resp.statusCode();

        if (status >= 200 && status < 300) {
            if (responseType == Void.class || resp.body().isBlank()) {
                return null;
            }
            return MAPPER.readValue(resp.body(), responseType);
        }

        // Parse error body
        String code = ErrorCodes.SERVER_ERROR;
        String message = "HTTP " + status;
        try {
            Map<?, ?> err = MAPPER.readValue(resp.body(), Map.class);
            if (err.containsKey("code")) code = err.get("code").toString();
            if (err.containsKey("message")) message = err.get("message").toString();
        } catch (Exception ignored) {}

        throw new RemitError(code, message, Map.of("http_status", status), status);
    }

    private String signRequest(String method, String path, String body, String nonce, String timestamp) {
        // EIP-712 inspired request signing:
        // hash(method + path + sha256(body) + nonce + timestamp + chainId)
        String payload = method + "\n" + path + "\n" + sha256Hex(body) + "\n" + nonce + "\n" + timestamp + "\n" + chainId;
        byte[] hash = keccak256(payload.getBytes(StandardCharsets.UTF_8));
        try {
            byte[] sig = signer.sign(hash);
            return HexFormat.of().formatHex(sig);
        } catch (Exception e) {
            throw new RemitError(ErrorCodes.INVALID_SIGNATURE,
                "Failed to sign request. Check that your private key is valid.",
                Map.of()
            );
        }
    }

    private String generateNonce() {
        byte[] b = new byte[16];
        new SecureRandom().nextBytes(b);
        return HexFormat.of().formatHex(b);
    }

    private static byte[] keccak256(byte[] input) {
        return org.web3j.crypto.Hash.sha3(input);
    }

    private static String sha256Hex(String input) {
        try {
            java.security.MessageDigest digest = java.security.MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(input.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(hash);
        } catch (Exception e) {
            return "";
        }
    }

    @FunctionalInterface
    private interface ThrowingSupplier<T> {
        T get() throws Exception;
    }

    private <T> T executeWithRetry(ThrowingSupplier<T> action) {
        RemitError lastError = null;
        for (int attempt = 0; attempt <= MAX_RETRIES; attempt++) {
            try {
                return action.get();
            } catch (RemitError e) {
                lastError = e;
                // Don't retry client errors (4xx) — only server errors (5xx)
                if (e.getHttpStatus() > 0 && e.getHttpStatus() < 500) {
                    throw e;
                }
                if (attempt < MAX_RETRIES) {
                    try {
                        Thread.sleep(BACKOFF_MS[attempt]);
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                        throw e;
                    }
                }
            } catch (Exception e) {
                lastError = new RemitError(ErrorCodes.SERVER_ERROR, "Request failed: " + e.getMessage(), Map.of());
                if (attempt < MAX_RETRIES) {
                    try {
                        Thread.sleep(BACKOFF_MS[attempt]);
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                        throw lastError;
                    }
                }
            }
        }
        throw lastError;
    }
}
