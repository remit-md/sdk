package md.remit;

import com.fasterxml.jackson.databind.ObjectMapper;
import md.remit.signer.Signer;

import java.math.BigInteger;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
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
 *   <li>Builds and signs an EIP-3009 {@code transferWithAuthorization}</li>
 *   <li>Base64-encodes the {@code PAYMENT-SIGNATURE} header</li>
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
    private static final SecureRandom RNG = new SecureRandom();

    private final Signer signer;
    private final String address;
    private final long chainId;
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
        // Access internal fields via package-private references
        this.signer = wallet.signer();
        this.address = wallet.address();
        this.chainId = wallet.chainId();
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

        // Parse chainId from CAIP-2 network string (e.g. "eip155:84532")
        String network = (String) required.get("network");
        long payChainId = Long.parseLong(network.split(":")[1]);

        String asset = (String) required.get("asset");
        String payTo = (String) required.get("payTo");
        Object timeoutObj = required.get("maxTimeoutSeconds");
        int maxTimeout = timeoutObj instanceof Number ? ((Number) timeoutObj).intValue() : 60;

        // Build EIP-3009 authorization
        long nowSecs = System.currentTimeMillis() / 1000;
        long validBefore = nowSecs + maxTimeout;
        byte[] nonceBytes = new byte[32];
        RNG.nextBytes(nonceBytes);
        String nonce = "0x" + HexFormat.of().formatHex(nonceBytes);

        // Sign EIP-712 transferWithAuthorization
        String signature = signEip3009(
            payChainId, asset, address, payTo,
            amountBaseUnits, 0, validBefore, nonceBytes);

        // Build PAYMENT-SIGNATURE JSON payload
        Map<String, Object> authorization = Map.of(
            "from", address,
            "to", payTo,
            "value", amountStr,
            "validAfter", "0",
            "validBefore", String.valueOf(validBefore),
            "nonce", nonce
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

    private String signEip3009(
            long chainId, String asset, String from, String to,
            long value, long validAfter, long validBefore, byte[] nonce) {

        byte[] domainTypeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                .getBytes(StandardCharsets.UTF_8));
        byte[] nameHash = keccak256("USD Coin".getBytes(StandardCharsets.UTF_8));
        byte[] versionHash = keccak256("2".getBytes(StandardCharsets.UTF_8));

        byte[] domainSep = keccak256(concat(
            domainTypeHash, nameHash, versionHash,
            toUint256(chainId), addressToBytes32(asset)));

        byte[] typeHash = keccak256(
            "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
                .getBytes(StandardCharsets.UTF_8));

        byte[] paddedNonce = new byte[32];
        System.arraycopy(nonce, 0, paddedNonce, 0, Math.min(nonce.length, 32));

        byte[] structHash = keccak256(concat(
            typeHash,
            addressToBytes32(from),
            addressToBytes32(to),
            toUint256(value),
            toUint256(validAfter),
            toUint256(validBefore),
            paddedNonce));

        byte[] finalData = new byte[2 + 32 + 32];
        finalData[0] = 0x19;
        finalData[1] = 0x01;
        System.arraycopy(domainSep, 0, finalData, 2, 32);
        System.arraycopy(structHash, 0, finalData, 34, 32);
        byte[] digest = keccak256(finalData);

        try {
            byte[] sig = signer.sign(digest);
            return "0x" + HexFormat.of().formatHex(sig);
        } catch (Exception e) {
            throw new RemitError(ErrorCodes.INVALID_SIGNATURE,
                "Failed to sign EIP-3009 authorization.",
                Map.of());
        }
    }

    private static byte[] keccak256(byte[] input) {
        return org.web3j.crypto.Hash.sha3(input);
    }

    private static byte[] toUint256(long value) {
        BigInteger bi = value >= 0 ? BigInteger.valueOf(value) : new BigInteger(Long.toUnsignedString(value));
        byte[] b = bi.toByteArray();
        byte[] result = new byte[32];
        int start = (b.length > 1 && b[0] == 0) ? 1 : 0;
        int len = b.length - start;
        System.arraycopy(b, start, result, 32 - len, len);
        return result;
    }

    private static byte[] addressToBytes32(String address) {
        if (address == null || address.isBlank()) return new byte[32];
        String hex = address.startsWith("0x") ? address.substring(2) : address;
        if (hex.length() != 40) return new byte[32];
        byte[] addr = HexFormat.of().parseHex(hex);
        byte[] result = new byte[32];
        System.arraycopy(addr, 0, result, 12, 20);
        return result;
    }

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
}
