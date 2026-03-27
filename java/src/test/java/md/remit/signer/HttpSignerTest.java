package md.remit.signer;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import md.remit.ErrorCodes;
import md.remit.RemitError;
import org.junit.jupiter.api.*;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.HexFormat;

import static org.assertj.core.api.Assertions.*;

@DisplayName("HttpSigner")
class HttpSignerTest {

    private static final String MOCK_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    // 65 bytes: 32 bytes r + 32 bytes s + 1 byte v
    private static final String MOCK_SIGNATURE = "0x" + "ab".repeat(32) + "cd".repeat(32) + "1b";
    private static final String VALID_TOKEN = "rmit_sk_" + "a1".repeat(32);

    private HttpServer server;
    private String url;

    @BeforeEach
    void startServer() throws IOException {
        server = HttpServer.create(new InetSocketAddress(0), 0);
        int port = server.getAddress().getPort();
        url = "http://127.0.0.1:" + port;

        // GET /address
        server.createContext("/address", exchange -> {
            if (!checkAuth(exchange)) return;
            respond(exchange, 200, "{\"address\":\"" + MOCK_ADDRESS + "\"}");
        });

        // POST /sign/digest
        server.createContext("/sign/digest", exchange -> {
            if (!checkAuth(exchange)) return;
            if (!"POST".equals(exchange.getRequestMethod())) {
                respond(exchange, 405, "{\"error\":\"method_not_allowed\"}");
                return;
            }
            respond(exchange, 200, "{\"signature\":\"" + MOCK_SIGNATURE + "\"}");
        });

        server.start();
    }

    @AfterEach
    void stopServer() {
        if (server != null) {
            server.stop(0);
        }
    }

    // ─── Happy path ──────────────────────────────────────────────────────────────

    @Test
    @DisplayName("constructor fetches and caches address")
    void testConstructorFetchesAddress() {
        HttpSigner signer = new HttpSigner(url, VALID_TOKEN);
        assertThat(signer.address()).isEqualTo(MOCK_ADDRESS);
    }

    @Test
    @DisplayName("sign returns 65-byte signature from server")
    void testSignReturnsSignature() throws Exception {
        HttpSigner signer = new HttpSigner(url, VALID_TOKEN);
        byte[] hash = new byte[32];
        for (int i = 0; i < 32; i++) hash[i] = (byte) i;

        byte[] sig = signer.sign(hash);

        assertThat(sig).hasSize(65);

        // Verify the signature matches the mock response
        String expectedClean = MOCK_SIGNATURE.substring(2); // strip 0x
        byte[] expected = HexFormat.of().parseHex(expectedClean);
        assertThat(sig).isEqualTo(expected);
    }

    @Test
    @DisplayName("address() returns cached address, not placeholder")
    void testAddressNotPlaceholder() {
        HttpSigner signer = new HttpSigner(url, VALID_TOKEN);
        assertThat(signer.address()).isNotEqualTo("0x0000000000000000000000000000000000000000");
        assertThat(signer.address()).isEqualTo(MOCK_ADDRESS);
    }

    // ─── Server unreachable ──────────────────────────────────────────────────────

    @Test
    @DisplayName("constructor throws NETWORK_ERROR when server unreachable")
    void testServerUnreachable() {
        assertThatThrownBy(() -> new HttpSigner("http://127.0.0.1:1", VALID_TOKEN))
            .isInstanceOf(RemitError.class)
            .satisfies(e -> {
                RemitError re = (RemitError) e;
                assertThat(re.getCode()).isEqualTo(ErrorCodes.NETWORK_ERROR);
                assertThat(re.getMessage()).contains("cannot reach");
            });
    }

    // ─── 401 Unauthorized ────────────────────────────────────────────────────────

    @Test
    @DisplayName("constructor throws UNAUTHORIZED on 401 from /address")
    void testUnauthorizedOnAddress() {
        assertThatThrownBy(() -> new HttpSigner(url, "bad_token"))
            .isInstanceOf(RemitError.class)
            .satisfies(e -> {
                RemitError re = (RemitError) e;
                assertThat(re.getCode()).isEqualTo(ErrorCodes.UNAUTHORIZED);
                assertThat(re.getMessage()).contains("unauthorized");
                assertThat(re.getHttpStatus()).isEqualTo(401);
            });
    }

    // ─── 403 Forbidden ───────────────────────────────────────────────────────────

    @Test
    @DisplayName("sign throws FORBIDDEN on 403 with reason")
    void testForbiddenWithReason() throws IOException {
        // Replace /sign/digest with a 403 handler
        server.removeContext("/sign/digest");
        server.createContext("/sign/digest", exchange -> {
            if (!checkAuth(exchange)) return;
            respond(exchange, 403, "{\"error\":\"policy_denied\",\"reason\":\"chain not allowed\"}");
        });

        HttpSigner signer = new HttpSigner(url, VALID_TOKEN);
        byte[] hash = new byte[32];

        assertThatThrownBy(() -> signer.sign(hash))
            .isInstanceOf(RemitError.class)
            .satisfies(e -> {
                RemitError re = (RemitError) e;
                assertThat(re.getCode()).isEqualTo(ErrorCodes.FORBIDDEN);
                assertThat(re.getMessage()).contains("policy denied");
                assertThat(re.getMessage()).contains("chain not allowed");
                assertThat(re.getHttpStatus()).isEqualTo(403);
            });
    }

    // ─── 500 Server Error ────────────────────────────────────────────────────────

    @Test
    @DisplayName("sign throws SERVER_ERROR on 500")
    void testServerError() throws IOException {
        server.removeContext("/sign/digest");
        server.createContext("/sign/digest", exchange -> {
            if (!checkAuth(exchange)) return;
            respond(exchange, 500, "{\"error\":\"internal_error\"}");
        });

        HttpSigner signer = new HttpSigner(url, VALID_TOKEN);
        byte[] hash = new byte[32];

        assertThatThrownBy(() -> signer.sign(hash))
            .isInstanceOf(RemitError.class)
            .satisfies(e -> {
                RemitError re = (RemitError) e;
                assertThat(re.getCode()).isEqualTo(ErrorCodes.SERVER_ERROR);
                assertThat(re.getMessage()).contains("500");
                assertThat(re.getHttpStatus()).isEqualTo(500);
            });
    }

    // ─── Malformed response ──────────────────────────────────────────────────────

    @Test
    @DisplayName("sign throws SERVER_ERROR on malformed response (no signature field)")
    void testMalformedResponse() throws IOException {
        server.removeContext("/sign/digest");
        server.createContext("/sign/digest", exchange -> {
            if (!checkAuth(exchange)) return;
            respond(exchange, 200, "{\"notSignature\":true}");
        });

        HttpSigner signer = new HttpSigner(url, VALID_TOKEN);
        byte[] hash = new byte[32];

        assertThatThrownBy(() -> signer.sign(hash))
            .isInstanceOf(RemitError.class)
            .satisfies(e -> {
                RemitError re = (RemitError) e;
                assertThat(re.getCode()).isEqualTo(ErrorCodes.SERVER_ERROR);
                assertThat(re.getMessage()).contains("no signature");
            });
    }

    // ─── Token not leaked ────────────────────────────────────────────────────────

    @Test
    @DisplayName("toString() does not leak token")
    void testToStringNoTokenLeak() {
        HttpSigner signer = new HttpSigner(url, VALID_TOKEN);
        String str = signer.toString();
        assertThat(str).doesNotContain(VALID_TOKEN);
        assertThat(str).contains(MOCK_ADDRESS);
    }

    // ─── Input validation ────────────────────────────────────────────────────────

    @Test
    @DisplayName("constructor throws INVALID_PARAM for null url")
    void testNullUrl() {
        assertThatThrownBy(() -> new HttpSigner(null, VALID_TOKEN))
            .isInstanceOf(RemitError.class)
            .satisfies(e -> {
                RemitError re = (RemitError) e;
                assertThat(re.getCode()).isEqualTo(ErrorCodes.INVALID_PARAM);
                assertThat(re.getMessage()).contains("url is required");
            });
    }

    @Test
    @DisplayName("constructor throws INVALID_PARAM for null token")
    void testNullToken() {
        assertThatThrownBy(() -> new HttpSigner(url, null))
            .isInstanceOf(RemitError.class)
            .satisfies(e -> {
                RemitError re = (RemitError) e;
                assertThat(re.getCode()).isEqualTo(ErrorCodes.INVALID_PARAM);
                assertThat(re.getMessage()).contains("token is required");
            });
    }

    @Test
    @DisplayName("sign throws INVALID_PARAM for wrong-length hash")
    void testWrongLengthHash() {
        HttpSigner signer = new HttpSigner(url, VALID_TOKEN);
        byte[] shortHash = new byte[16];

        assertThatThrownBy(() -> signer.sign(shortHash))
            .isInstanceOf(RemitError.class)
            .satisfies(e -> {
                RemitError re = (RemitError) e;
                assertThat(re.getCode()).isEqualTo(ErrorCodes.INVALID_PARAM);
                assertThat(re.getMessage()).contains("32 bytes");
            });
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    private boolean checkAuth(HttpExchange exchange) throws IOException {
        String auth = exchange.getRequestHeaders().getFirst("Authorization");
        if (auth == null || !auth.equals("Bearer " + VALID_TOKEN)) {
            respond(exchange, 401, "{\"error\":\"unauthorized\"}");
            return false;
        }
        return true;
    }

    private static void respond(HttpExchange exchange, int status, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }
}
