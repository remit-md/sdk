package md.remit;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import md.remit.models.Balance;
import md.remit.models.Transaction;
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

    /** Set to false when the server health-check fails — all tests skip. */
    private static boolean serverAvailable = false;

    /** Shared funded payer wallet — only one faucet drip per test run. */
    private static final AtomicReference<Wallet> SHARED_PAYER = new AtomicReference<>();
    private static final AtomicReference<String> SHARED_PAYER_ADDR = new AtomicReference<>();

    @BeforeAll
    static void checkServerAvailability() {
        try {
            HttpRequest req = HttpRequest.newBuilder()
                .uri(URI.create(SERVER_URL + "/health"))
                .timeout(Duration.ofSeconds(3))
                .GET()
                .build();
            HttpResponse<Void> resp = HTTP.send(req, HttpResponse.BodyHandlers.discarding());
            serverAvailable = resp.statusCode() == 200;
        } catch (Exception ignored) {
            serverAvailable = false;
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

    /** Register a new operator and return (privateKey, walletAddress). */
    private static String[] registerAndGetKey() throws Exception {
        String email = "compliance.java." + System.currentTimeMillis() + "@test.remitmd.local";
        String regBody = MAPPER.writeValueAsString(
            java.util.Map.of("email", email, "password", "ComplianceTestPass1!"));
        JsonNode reg = MAPPER.readTree(post("/api/v0/auth/register", regBody, null));
        String token = reg.get("token").asText();
        String walletAddr = reg.get("wallet_address").asText();

        JsonNode keyData = MAPPER.readTree(getWithAuth("/api/v0/auth/agent-key", token));
        String privateKey = keyData.get("private_key").asText();

        return new String[]{privateKey, walletAddr};
    }

    /** Fund a wallet via the faucet (no auth required on testnet). */
    private static void fundWallet(String walletAddress) throws Exception {
        String body = MAPPER.writeValueAsString(
            java.util.Map.of("wallet", walletAddress, "amount", 1000));
        JsonNode resp = MAPPER.readTree(post("/api/v0/faucet", body, null));
        assertThat(resp.has("tx_hash"))
            .as("faucet response must contain tx_hash, got: " + resp)
            .isTrue();
    }

    /** Return (or lazily create) the shared funded payer wallet. */
    private static Wallet getSharedPayer() throws Exception {
        if (SHARED_PAYER.get() != null) {
            return SHARED_PAYER.get();
        }
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
        return payer;
    }

    // ─── Auth tests ───────────────────────────────────────────────────────────

    @Test
    void authenticatedRequest_returnsWalletBalance_not401() throws Exception {
        assumeTrue(serverAvailable, "Compliance server not reachable at " + SERVER_URL);

        String[] keyAddr = registerAndGetKey();
        Wallet wallet = RemitMd.withKey(keyAddr[0])
            .chain("base")
            .testnet(true)
            .baseUrl(SERVER_URL)
            .routerAddress(ROUTER_ADDRESS)
            .build();

        Balance balance = wallet.balance();
        assertThat(balance).as("balance() must not throw 401").isNotNull();
    }

    @Test
    void unauthenticatedRequest_returns401() throws Exception {
        assumeTrue(serverAvailable, "Compliance server not reachable at " + SERVER_URL);

        HttpRequest req = HttpRequest.newBuilder()
            .uri(URI.create(SERVER_URL + "/api/v0/payments/direct"))
            .timeout(Duration.ofSeconds(5))
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(
                "{\"to\":\"0x70997970C51812dc3A010C7d01b50e0d17dc79C8\",\"amount\":\"1.000000\"}"))
            .build();
        HttpResponse<String> resp = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
        assertThat(resp.statusCode())
            .as("unauthenticated POST /payments/direct must return 401")
            .isEqualTo(401);
    }

    // ─── Payment tests ────────────────────────────────────────────────────────

    @Test
    void payDirect_happyPath_returnsTxHash() throws Exception {
        assumeTrue(serverAvailable, "Compliance server not reachable at " + SERVER_URL);

        Wallet payer = getSharedPayer();
        String[] payeeKeyAddr = registerAndGetKey();
        String payeeAddr = payeeKeyAddr[1];

        Transaction tx = payer.pay(payeeAddr, new BigDecimal("5.0"), "java compliance test");

        assertThat(tx.txHash)
            .as("pay() must return a non-empty tx_hash")
            .isNotEmpty();
    }

    @Test
    void payDirect_belowMinimum_throwsRemitError() throws Exception {
        assumeTrue(serverAvailable, "Compliance server not reachable at " + SERVER_URL);

        Wallet payer = getSharedPayer();
        String[] payeeKeyAddr = registerAndGetKey();
        String payeeAddr = payeeKeyAddr[1];

        RemitError caught = null;
        try {
            payer.pay(payeeAddr, new BigDecimal("0.0001"), "too small");
        } catch (RemitError e) {
            caught = e;
        }
        assertThat(caught)
            .as("pay() with amount below minimum must throw RemitError")
            .isNotNull();
    }
}
