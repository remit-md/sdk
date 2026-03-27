package md.remit.signer;

import md.remit.ErrorCodes;
import md.remit.RemitError;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.HexFormat;
import java.util.Map;

/**
 * Signs EIP-712 hashes by delegating to a local HTTP signing server.
 *
 * <p>The signer server (typically {@code http://127.0.0.1:7402}) holds the
 * encrypted key; this adapter only needs a bearer token and URL.
 *
 * <p>The address is fetched and cached during construction (GET /address).
 * The token is stored privately and never appears in error messages or toString().
 *
 * <pre>{@code
 * Signer signer = new HttpSigner("http://127.0.0.1:7402", "rmit_sk_...");
 * Wallet wallet = RemitMd.withSigner(signer).build();
 * }</pre>
 */
public class HttpSigner implements Signer {

    private static final Duration TIMEOUT = Duration.ofSeconds(10);

    private final String url;
    private final String token;
    private final String address;
    private final HttpClient httpClient;

    /**
     * Creates an HttpSigner, fetching and caching the wallet address from the server.
     *
     * @param url   signer server URL (e.g., "http://127.0.0.1:7402")
     * @param token bearer token for authentication
     * @throws RemitError if the server is unreachable, returns an error, or returns no address
     */
    public HttpSigner(String url, String token) {
        if (url == null || url.isBlank()) {
            throw new RemitError(
                ErrorCodes.INVALID_PARAM,
                "HttpSigner: url is required.",
                Map.of("hint", "Set REMIT_SIGNER_URL to the signer server URL")
            );
        }
        if (token == null || token.isBlank()) {
            throw new RemitError(
                ErrorCodes.INVALID_PARAM,
                "HttpSigner: token is required.",
                Map.of("hint", "Set REMIT_SIGNER_TOKEN to the signer bearer token")
            );
        }

        this.url = url.replaceAll("/+$", "");
        this.token = token;
        this.httpClient = HttpClient.newBuilder()
            .connectTimeout(TIMEOUT)
            .build();

        // Fetch and cache the address
        this.address = fetchAddress();
    }

    @Override
    public byte[] sign(byte[] hash) {
        if (hash == null || hash.length != 32) {
            throw new RemitError(
                ErrorCodes.INVALID_PARAM,
                "HttpSigner: hash must be exactly 32 bytes.",
                Map.of("length", hash == null ? 0 : hash.length)
            );
        }

        String hexDigest = "0x" + HexFormat.of().formatHex(hash);
        String body = "{\"digest\":\"" + hexDigest + "\"}";

        HttpRequest request = HttpRequest.newBuilder()
            .uri(URI.create(url + "/sign/digest"))
            .timeout(TIMEOUT)
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer " + token)
            .POST(HttpRequest.BodyPublishers.ofString(body))
            .build();

        HttpResponse<String> response;
        try {
            response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        } catch (IOException e) {
            throw new RemitError(
                ErrorCodes.NETWORK_ERROR,
                "HttpSigner: cannot reach signer server at " + url + ": " + e.getMessage(),
                Map.of("url", url)
            );
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RemitError(
                ErrorCodes.TIMEOUT,
                "HttpSigner: request interrupted.",
                Map.of("url", url)
            );
        }

        handleErrorResponse(response, "POST /sign/digest");

        String sig = extractJsonField(response.body(), "signature");
        if (sig == null || sig.isBlank()) {
            throw new RemitError(
                ErrorCodes.SERVER_ERROR,
                "HttpSigner: server returned no signature.",
                Map.of()
            );
        }

        return parseHexSignature(sig);
    }

    @Override
    public String address() {
        return address;
    }

    /**
     * Prevent token leakage in logs and debugging output.
     */
    @Override
    public String toString() {
        return "HttpSigner{address=" + address + "}";
    }

    // ─── Internal ────────────────────────────────────────────────────────────────

    private String fetchAddress() {
        HttpRequest request = HttpRequest.newBuilder()
            .uri(URI.create(url + "/address"))
            .timeout(TIMEOUT)
            .header("Authorization", "Bearer " + token)
            .GET()
            .build();

        HttpResponse<String> response;
        try {
            response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        } catch (IOException e) {
            throw new RemitError(
                ErrorCodes.NETWORK_ERROR,
                "HttpSigner: cannot reach signer server at " + url + ": " + e.getMessage(),
                Map.of("url", url)
            );
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RemitError(
                ErrorCodes.TIMEOUT,
                "HttpSigner: request interrupted.",
                Map.of("url", url)
            );
        }

        handleErrorResponse(response, "GET /address");

        String addr = extractJsonField(response.body(), "address");
        if (addr == null || addr.isBlank()) {
            throw new RemitError(
                ErrorCodes.SERVER_ERROR,
                "HttpSigner: GET /address returned no address.",
                Map.of()
            );
        }
        return addr;
    }

    private void handleErrorResponse(HttpResponse<String> response, String endpoint) {
        int status = response.statusCode();
        if (status >= 200 && status < 300) {
            return;
        }

        if (status == 401) {
            throw new RemitError(
                ErrorCodes.UNAUTHORIZED,
                "HttpSigner: unauthorized — check your REMIT_SIGNER_TOKEN.",
                Map.of("endpoint", endpoint),
                401
            );
        }

        if (status == 403) {
            String reason = extractJsonField(response.body(), "reason");
            if (reason == null || reason.isBlank()) {
                reason = "unknown reason";
            }
            throw new RemitError(
                ErrorCodes.FORBIDDEN,
                "HttpSigner: policy denied — " + reason,
                Map.of("endpoint", endpoint),
                403
            );
        }

        // All other non-2xx
        String detail = extractJsonField(response.body(), "reason");
        if (detail == null || detail.isBlank()) {
            detail = extractJsonField(response.body(), "error");
        }
        if (detail == null || detail.isBlank()) {
            detail = response.body();
        }
        throw new RemitError(
            ErrorCodes.SERVER_ERROR,
            "HttpSigner: " + endpoint + " failed (" + status + "): " + detail,
            Map.of("endpoint", endpoint, "status", status),
            status
        );
    }

    /**
     * Minimal JSON field extraction without external dependencies.
     * Handles simple {"key": "value"} patterns. Not a full parser,
     * but sufficient for the small, well-formed signer server responses.
     */
    private static String extractJsonField(String json, String field) {
        if (json == null || json.isBlank()) {
            return null;
        }
        // Look for "field": "value" or "field":"value"
        String pattern = "\"" + field + "\"";
        int keyIndex = json.indexOf(pattern);
        if (keyIndex < 0) {
            return null;
        }
        int colonIndex = json.indexOf(':', keyIndex + pattern.length());
        if (colonIndex < 0) {
            return null;
        }
        // Find the opening quote of the value
        int openQuote = json.indexOf('"', colonIndex + 1);
        if (openQuote < 0) {
            return null;
        }
        int closeQuote = json.indexOf('"', openQuote + 1);
        if (closeQuote < 0) {
            return null;
        }
        return json.substring(openQuote + 1, closeQuote);
    }

    private static byte[] parseHexSignature(String hex) {
        String clean = hex.startsWith("0x") ? hex.substring(2) : hex;
        try {
            byte[] bytes = HexFormat.of().parseHex(clean);
            if (bytes.length != 65) {
                throw new RemitError(
                    ErrorCodes.SERVER_ERROR,
                    "HttpSigner: expected 65-byte signature, got " + bytes.length + " bytes.",
                    Map.of("length", bytes.length)
                );
            }
            return bytes;
        } catch (IllegalArgumentException e) {
            throw new RemitError(
                ErrorCodes.SERVER_ERROR,
                "HttpSigner: server returned malformed signature hex.",
                Map.of()
            );
        }
    }
}
