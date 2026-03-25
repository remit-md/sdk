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
import java.util.Arrays;
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
    private final String routerAddress;
    private final Signer signer;

    public ApiClient(String baseUrl, long chainId, String routerAddress, Signer signer) {
        this.baseUrl = baseUrl.endsWith("/") ? baseUrl.substring(0, baseUrl.length() - 1) : baseUrl;
        this.chainId = chainId;
        this.routerAddress = routerAddress != null ? routerAddress : "";
        this.signer = signer;
        this.http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();
    }

    public <T> T get(String path, Class<T> responseType) {
        return executeWithRetry(() -> doGet(path, responseType));
    }

    public <T> T post(String path, Object body, Class<T> responseType) {
        // Generate idempotency key once per request (stable across retries).
        byte[] keyBytes = new byte[16];
        new SecureRandom().nextBytes(keyBytes);
        String idempotencyKey = HexFormat.of().formatHex(keyBytes);
        return executeWithRetry(() -> doPost(path, body, responseType, idempotencyKey));
    }

    private <T> T doGet(String path, Class<T> responseType) throws Exception {
        byte[] nonce = generateNonce();
        String nonceHex = "0x" + HexFormat.of().formatHex(nonce);
        long timestamp = Instant.now().getEpochSecond();
        String signPath = path.contains("?") ? path.substring(0, path.indexOf("?")) : path;
        String signature = signEip712("GET", signPath, timestamp, nonce);

        HttpRequest req = HttpRequest.newBuilder()
            .uri(URI.create(baseUrl + path))
            .header("Accept", "application/json")
            .header("X-Remit-Agent", signer.address())
            .header("X-Remit-Nonce", nonceHex)
            .header("X-Remit-Timestamp", String.valueOf(timestamp))
            .header("X-Remit-Signature", signature)
            .timeout(Duration.ofSeconds(30))
            .GET()
            .build();

        HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
        return handleResponse(resp, responseType);
    }

    private <T> T doPost(String path, Object body, Class<T> responseType, String idempotencyKey) throws Exception {
        String bodyJson = body != null ? MAPPER.writeValueAsString(body) : "{}";
        byte[] nonce = generateNonce();
        String nonceHex = "0x" + HexFormat.of().formatHex(nonce);
        long timestamp = Instant.now().getEpochSecond();
        String signPath = path.contains("?") ? path.substring(0, path.indexOf("?")) : path;
        String signature = signEip712("POST", signPath, timestamp, nonce);

        HttpRequest.Builder builder = HttpRequest.newBuilder()
            .uri(URI.create(baseUrl + path))
            .header("Content-Type", "application/json")
            .header("Accept", "application/json")
            .header("X-Remit-Agent", signer.address())
            .header("X-Remit-Nonce", nonceHex)
            .header("X-Remit-Timestamp", String.valueOf(timestamp))
            .header("X-Remit-Signature", signature)
            .timeout(Duration.ofSeconds(30));

        if (idempotencyKey != null) {
            builder.header("X-Idempotency-Key", idempotencyKey);
        }

        HttpRequest req = builder
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

        // Parse error body — supports both flat {"code":"...", "message":"..."}
        // and nested {"error": {"code":"...", "message":"..."}} formats.
        String code = ErrorCodes.SERVER_ERROR;
        String message = "HTTP " + status;
        try {
            Map<?, ?> err = MAPPER.readValue(resp.body(), Map.class);
            // Check for nested {"error": {...}} wrapper
            if (err.containsKey("error") && err.get("error") instanceof Map) {
                err = (Map<?, ?>) err.get("error");
            }
            if (err.containsKey("code")) code = err.get("code").toString();
            if (err.containsKey("message")) message = err.get("message").toString();
        } catch (Exception ignored) {}

        throw new RemitError(code, message, Map.of("http_status", status), status);
    }

    // ─── EIP-712 ─────────────────────────────────────────────────────────────

    /**
     * Computes the EIP-712 hash for an APIRequest and signs it.
     *
     * <p>Domain: name="remit.md", version="0.1", chainId, verifyingContract<br>
     * Struct: APIRequest(string method, string path, uint256 timestamp, bytes32 nonce)
     */
    private String signEip712(String method, String path, long timestamp, byte[] nonce) {
        byte[] digest = computeEip712Hash(chainId, routerAddress, method, path, timestamp, nonce);
        try {
            byte[] sig = signer.sign(digest);
            return "0x" + HexFormat.of().formatHex(sig);
        } catch (Exception e) {
            throw new RemitError(ErrorCodes.INVALID_SIGNATURE,
                "Failed to sign request. Check that your private key is valid.",
                Map.of()
            );
        }
    }

    public static byte[] computeEip712Hash(
            long chainId,
            String routerAddress,
            String method,
            String path,
            long timestamp,
            byte[] nonce) {
        // Type hashes.
        byte[] domainTypeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                .getBytes(StandardCharsets.UTF_8));
        byte[] requestTypeHash = keccak256(
            "APIRequest(string method,string path,uint256 timestamp,bytes32 nonce)"
                .getBytes(StandardCharsets.UTF_8));

        // Domain separator components.
        byte[] nameHash = keccak256("remit.md".getBytes(StandardCharsets.UTF_8));
        byte[] versionHash = keccak256("0.1".getBytes(StandardCharsets.UTF_8));
        byte[] chainIdBytes = toUint256(chainId);
        byte[] contractBytes = addressToBytes32(routerAddress);

        byte[] domainData = concat(domainTypeHash, nameHash, versionHash, chainIdBytes, contractBytes);
        byte[] domainSeparator = keccak256(domainData);

        // Struct hash.
        byte[] methodHash = keccak256(method.getBytes(StandardCharsets.UTF_8));
        byte[] pathHash = keccak256(path.getBytes(StandardCharsets.UTF_8));
        byte[] timestampBytes = toUint256(timestamp);
        // nonce is already 32 bytes (bytes32)
        byte[] paddedNonce = new byte[32];
        System.arraycopy(nonce, 0, paddedNonce, 0, Math.min(nonce.length, 32));

        byte[] structData = concat(requestTypeHash, methodHash, pathHash, timestampBytes, paddedNonce);
        byte[] structHash = keccak256(structData);

        // Final EIP-712 hash: "\x19\x01" || domainSeparator || structHash
        byte[] finalData = new byte[2 + 32 + 32];
        finalData[0] = 0x19;
        finalData[1] = 0x01;
        System.arraycopy(domainSeparator, 0, finalData, 2, 32);
        System.arraycopy(structHash, 0, finalData, 34, 32);
        return keccak256(finalData);
    }

    private static byte[] keccak256(byte[] input) {
        return org.web3j.crypto.Hash.sha3(input);
    }

    /** Encode a long as ABI uint256 (32 bytes, big-endian, unsigned). */
    public static byte[] toUint256(long value) {
        // Use Long.toUnsignedString so that large u64 values (e.g. u64::MAX stored as -1L)
        // are treated as positive unsigned integers.
        BigInteger unsigned = new BigInteger(Long.toUnsignedString(value));
        byte[] b = unsigned.toByteArray();
        byte[] result = new byte[32];
        // BigInteger.toByteArray() may include a leading 0 sign byte — strip it.
        int start = (b.length > 1 && b[0] == 0) ? 1 : 0;
        int len = b.length - start;
        System.arraycopy(b, start, result, 32 - len, len);
        return result;
    }

    /** Encode a 20-byte Ethereum address as ABI bytes32 (left-zero-padded). */
    private static byte[] addressToBytes32(String address) {
        if (address == null || address.isBlank()) return new byte[32];
        String hex = address.startsWith("0x") ? address.substring(2) : address;
        if (hex.length() != 40) return new byte[32];
        byte[] addr = HexFormat.of().parseHex(hex);
        byte[] result = new byte[32];
        System.arraycopy(addr, 0, result, 12, 20);
        return result;
    }

    /** Concatenate multiple byte arrays. */
    private static byte[] concat(byte[]... arrays) {
        int total = 0;
        for (byte[] a : arrays) total += a.length;
        byte[] result = new byte[total];
        int pos = 0;
        for (byte[] a : arrays) {
            System.arraycopy(a, 0, result, pos, a.length);
            pos += a.length;
        }
        return result;
    }

    /** Generate a random 32-byte nonce. */
    private static byte[] generateNonce() {
        byte[] b = new byte[32];
        new SecureRandom().nextBytes(b);
        return b;
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
