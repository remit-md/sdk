package md.remit;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import md.remit.models.Transaction;
import md.remit.models.TransactionList;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * Compliance tests: Java SDK against a real running server.
 *
 * <p>Tests are skipped when the server is unreachable. Boot the server with:
 * <pre>
 *   docker compose -f docker-compose.compliance.yml up -d
 * </pre>
 *
 * <p>Environment variables:
 * <ul>
 *   <li>REMIT_TEST_SERVER_URL (default: http://localhost:3000)</li>
 *   <li>REMIT_ROUTER_ADDRESS  (default: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8)</li>
 * </ul>
 */
class ComplianceTest {

    private static final String SERVER_URL =
        envOrDefault("REMIT_TEST_SERVER_URL", "http://localhost:3000");
    private static final String ROUTER_ADDRESS =
        envOrDefault("REMIT_ROUTER_ADDRESS", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8");

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final HttpClient HTTP = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(5))
        .build();

    /** Set to false when the server health-check fails - all tests skip. */
    private static boolean serverAvailable = false;

    /** Shared funded payer wallet - only one mint per test run. */
    private static final AtomicReference<Wallet> SHARED_PAYER = new AtomicReference<>();
    private static final AtomicReference<String> SHARED_PAYER_ADDR = new AtomicReference<>();

    @BeforeAll
    static void checkServerAvailability() {
        System.out.println("[COMPLIANCE] checking server availability at " + SERVER_URL + "/health");
        try {
            HttpRequest req = HttpRequest.newBuilder()
                .uri(URI.create(SERVER_URL + "/health"))
                .timeout(Duration.ofSeconds(3))
                .GET()
                .build();
            HttpResponse<Void> resp = HTTP.send(req, HttpResponse.BodyHandlers.discarding());
            serverAvailable = resp.statusCode() == 200;
            System.out.println("[COMPLIANCE] server health check: status=" + resp.statusCode() + " available=" + serverAvailable);
        } catch (Exception ignored) {
            serverAvailable = false;
            System.out.println("[COMPLIANCE] server health check: UNREACHABLE (tests will be skipped)");
        }
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static String envOrDefault(String key, String defaultValue) {
        String val = System.getenv(key);
        return (val != null && !val.isBlank()) ? val : defaultValue;
    }

    private static String post(String path, String jsonBody, String bearerToken) throws Exception {
        HttpRequest.Builder builder = HttpRequest.newBuilder()
            .uri(URI.create(SERVER_URL + path))
            .timeout(Duration.ofSeconds(10))
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(jsonBody));
        if (bearerToken != null) {
            builder.header("Authorization", "Bearer " + bearerToken);
        }
        HttpResponse<String> resp = HTTP.send(builder.build(), HttpResponse.BodyHandlers.ofString());
        return resp.body();
    }

    private static String getWithAuth(String path, String bearerToken) throws Exception {
        HttpResponse<String> resp = HTTP.send(
            HttpRequest.newBuilder()
                .uri(URI.create(SERVER_URL + path))
                .timeout(Duration.ofSeconds(10))
                .header("Authorization", "Bearer " + bearerToken)
                .GET()
                .build(),
            HttpResponse.BodyHandlers.ofString()
        );
        return resp.body();
    }

    /** Generate a random private key and derive the wallet address. */
    private static String[] registerAndGetKey() throws Exception {
        System.out.println("[COMPLIANCE] generating random private key...");
        byte[] keyBytes = new byte[32];
        new java.security.SecureRandom().nextBytes(keyBytes);
        StringBuilder sb = new StringBuilder("0x");
        for (byte b : keyBytes) {
            sb.append(String.format("%02x", b));
        }
        String privateKey = sb.toString();

        Wallet wallet = RemitMd.withKey(privateKey)
            .chain("base")
            .testnet(true)
            .baseUrl(SERVER_URL)
            .routerAddress(ROUTER_ADDRESS)
            .build();

        System.out.println("[COMPLIANCE] wallet created: " + wallet.address() + " (chain=" + wallet.chainId() + ")");
        return new String[]{privateKey, wallet.address()};
    }

    /** Fund a wallet via mint (no auth required on testnet). */
    private static void fundWallet(String walletAddress) throws Exception {
        System.out.println("[COMPLIANCE] mint: 1000 USDC -> " + walletAddress);
        String body = MAPPER.writeValueAsString(
            java.util.Map.of("wallet", walletAddress, "amount", 1000));
        JsonNode resp = MAPPER.readTree(post("/api/v1/mint", body, null));
        assertThat(resp.has("tx_hash"))
            .as("mint response must contain tx_hash, got: " + resp)
            .isTrue();
        System.out.println("[COMPLIANCE] mint: 1000 USDC -> " + walletAddress + " tx=" + resp.get("tx_hash").asText());
    }

    /** Return (or lazily create) the shared funded payer wallet. */
    private static Wallet getSharedPayer() throws Exception {
        if (SHARED_PAYER.get() != null) {
            System.out.println("[COMPLIANCE] reusing shared payer: " + SHARED_PAYER.get().address());
            return SHARED_PAYER.get();
        }
        System.out.println("[COMPLIANCE] creating shared payer wallet...");
        String[] keyAddr = registerAndGetKey();
        String privateKey = keyAddr[0];
        String walletAddr = keyAddr[1];
        fundWallet(walletAddr);
        Wallet payer = RemitMd.withKey(privateKey)
            .chain("base")
            .testnet(true)
            .baseUrl(SERVER_URL)
            .routerAddress(ROUTER_ADDRESS)
            .build();
        SHARED_PAYER.set(payer);
        SHARED_PAYER_ADDR.set(walletAddr);
        System.out.println("[COMPLIANCE] shared payer ready: " + payer.address() + " (funded 1000 USDC)");
        return payer;
    }

    // ─── Auth tests ───────────────────────────────────────────────────────────

    @Test
    void authenticatedRequest_returnsWalletBalance_not401() throws Exception {
        assumeTrue(serverAvailable, "Compliance server not reachable at " + SERVER_URL);
        System.out.println("[COMPLIANCE] test: authenticatedRequest_returnsWalletBalance_not401");

        String[] keyAddr = registerAndGetKey();
        Wallet wallet = RemitMd.withKey(keyAddr[0])
            .chain("base")
            .testnet(true)
            .baseUrl(SERVER_URL)
            .routerAddress(ROUTER_ADDRESS)
            .build();
        System.out.println("[COMPLIANCE] auth wallet created: " + wallet.address() + " (chain=" + wallet.chainId() + ")");

        // reputation() makes an authenticated GET to /api/v1/reputation/{address} -
        // this endpoint exists for all registered addresses and returns 401 if auth fails.
        System.out.println("[COMPLIANCE] calling reputation(" + wallet.address() + ") with auth...");
        var rep = wallet.reputation(wallet.address());
        assertThat(rep).as("reputation() must not throw 401").isNotNull();
        System.out.println("[COMPLIANCE] reputation returned successfully (auth verified, no 401)");
    }

    @Test
    void unauthenticatedRequest_returns401() throws Exception {
        assumeTrue(serverAvailable, "Compliance server not reachable at " + SERVER_URL);
        System.out.println("[COMPLIANCE] test: unauthenticatedRequest_returns401");

        System.out.println("[COMPLIANCE] sending unauthenticated POST /api/v1/payments/direct...");
        HttpRequest req = HttpRequest.newBuilder()
            .uri(URI.create(SERVER_URL + "/api/v1/payments/direct"))
            .timeout(Duration.ofSeconds(5))
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(
                "{\"to\":\"0x70997970C51812dc3A010C7d01b50e0d17dc79C8\",\"amount\":\"1.000000\"}"))
            .build();
        HttpResponse<String> resp = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
        System.out.println("[COMPLIANCE] unauthenticated response: status=" + resp.statusCode() + " body=" + resp.body());
        assertThat(resp.statusCode())
            .as("unauthenticated POST /payments/direct must return 401")
            .isEqualTo(401);
        System.out.println("[COMPLIANCE] 401 confirmed for unauthenticated request");
    }

    // ─── Payment tests ────────────────────────────────────────────────────────

    @Test
    void payDirect_happyPath_returnsTxHash() throws Exception {
        assumeTrue(serverAvailable, "Compliance server not reachable at " + SERVER_URL);
        System.out.println("[COMPLIANCE] test: payDirect_happyPath_returnsTxHash");

        Wallet payer = getSharedPayer();
        String[] payeeKeyAddr = registerAndGetKey();
        String payeeAddr = payeeKeyAddr[1];
        System.out.println("[COMPLIANCE] payee wallet created: " + payeeAddr);

        try {
            System.out.println("[COMPLIANCE] pay: 5.0 USDC " + payer.address() + " -> " + payeeAddr + " memo=\"java compliance test\"");
            Transaction tx = payer.pay(payeeAddr, new BigDecimal("5.0"), "java compliance test");
            assertThat(tx.txHash)
                .as("pay() must return a non-empty tx_hash")
                .isNotEmpty();
            System.out.println("[COMPLIANCE] pay: 5.0 USDC " + payer.address() + " -> " + payeeAddr
                + " tx=" + tx.txHash + " id=" + tx.id + " fee=" + tx.fee);
        } catch (RemitError e) {
            System.err.println("[COMPLIANCE] pay() FAILED: code=" + e.getCode()
                + " message=" + e.getMessage() + " httpStatus=" + e.getHttpStatus()
                + " payerAddr=" + payer.address());
            throw e;
        }
    }

    @Test
    void payDirect_belowMinimum_throwsRemitError() throws Exception {
        assumeTrue(serverAvailable, "Compliance server not reachable at " + SERVER_URL);
        System.out.println("[COMPLIANCE] test: payDirect_belowMinimum_throwsRemitError");

        Wallet payer = getSharedPayer();
        String[] payeeKeyAddr = registerAndGetKey();
        String payeeAddr = payeeKeyAddr[1];
        System.out.println("[COMPLIANCE] payee wallet created: " + payeeAddr);

        RemitError caught = null;
        try {
            System.out.println("[COMPLIANCE] pay: 0.0001 USDC " + payer.address() + " -> " + payeeAddr + " (expect rejection)");
            payer.pay(payeeAddr, new BigDecimal("0.0001"), "too small");
        } catch (RemitError e) {
            caught = e;
            System.out.println("[COMPLIANCE] below-minimum correctly rejected: code=" + e.getCode()
                + " message=" + e.getMessage() + " httpStatus=" + e.getHttpStatus());
        }
        assertThat(caught)
            .as("pay() with amount below minimum must throw RemitError")
            .isNotNull();
        System.out.println("[COMPLIANCE] below-minimum test passed");
    }
}
