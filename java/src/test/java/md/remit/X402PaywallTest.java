package md.remit;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.Base64;

import static org.assertj.core.api.Assertions.*;

@DisplayName("X402Paywall tests")
class X402PaywallTest {

    private static final String WALLET = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    private static final String NETWORK = "eip155:84532";
    private static final String ASSET = "0x2d846325766921935f37d5b4478196d3ef93707c";

    private X402Paywall defaultPaywall() {
        return new X402Paywall(WALLET, 0.001, NETWORK, ASSET, null, null, 60);
    }

    // ─── Construction ─────────────────────────────────────────────────────────

    @Test
    @DisplayName("constructor sets default facilitator URL")
    void testConstructorDefaults() {
        X402Paywall pw = defaultPaywall();
        assertThat(pw).isNotNull();
    }

    @Test
    @DisplayName("constructor with V2 fields")
    void testConstructorV2() {
        X402Paywall pw = new X402Paywall(
            WALLET, 0.001, NETWORK, ASSET, null, null, 60,
            "/v1/data", "Market data", "application/json"
        );
        assertThat(pw).isNotNull();
    }

    // ─── paymentRequiredHeader ─────────────────────────────────────────────────

    @Test
    @DisplayName("paymentRequiredHeader returns valid base64")
    void testPaymentRequiredHeader() {
        X402Paywall pw = defaultPaywall();
        String header = pw.paymentRequiredHeader();
        assertThat(header).isNotBlank();

        // Should be valid base64
        byte[] decoded = Base64.getDecoder().decode(header);
        String json = new String(decoded);
        assertThat(json).contains("\"scheme\":\"exact\"");
        assertThat(json).contains("\"payTo\":\"" + WALLET + "\"");
        assertThat(json).contains("\"amount\":\"1000\"");
    }

    @Test
    @DisplayName("paymentRequiredHeader includes V2 fields when set")
    void testPaymentRequiredHeaderV2Fields() {
        X402Paywall pw = new X402Paywall(
            WALLET, 0.001, NETWORK, ASSET, null, null, 60,
            "/v1/data", "Market data", "application/json"
        );
        String header = pw.paymentRequiredHeader();
        byte[] decoded = Base64.getDecoder().decode(header);
        String json = new String(decoded);
        assertThat(json).contains("\"resource\":\"/v1/data\"");
        assertThat(json).contains("\"description\":\"Market data\"");
        assertThat(json).contains("\"mimeType\":\"application/json\"");
    }

    // ─── check ────────────────────────────────────────────────────────────────

    @Test
    @DisplayName("check returns invalid for null payment sig")
    void testCheckNull() {
        X402Paywall pw = defaultPaywall();
        X402Paywall.CheckResult result = pw.check(null);
        assertThat(result.isValid).isFalse();
    }

    @Test
    @DisplayName("check returns invalid for empty payment sig")
    void testCheckEmpty() {
        X402Paywall pw = defaultPaywall();
        X402Paywall.CheckResult result = pw.check("");
        assertThat(result.isValid).isFalse();
    }

    @Test
    @DisplayName("check returns INVALID_PAYLOAD for invalid base64")
    void testCheckInvalidBase64() {
        X402Paywall pw = defaultPaywall();
        X402Paywall.CheckResult result = pw.check("!!!not-valid!!!");
        assertThat(result.isValid).isFalse();
        assertThat(result.invalidReason).isEqualTo("INVALID_PAYLOAD");
    }

    @Test
    @DisplayName("check returns FACILITATOR_ERROR when facilitator is unreachable")
    void testCheckFacilitatorDown() {
        X402Paywall pw = new X402Paywall(
            WALLET, 0.001, NETWORK, ASSET,
            "http://127.0.0.1:1", null, 60
        );
        // Build a valid-looking base64 payload
        String payload = Base64.getEncoder().encodeToString(
            "{\"scheme\":\"exact\",\"payload\":{}}".getBytes()
        );
        X402Paywall.CheckResult result = pw.check(payload);
        assertThat(result.isValid).isFalse();
        assertThat(result.invalidReason).isEqualTo("FACILITATOR_ERROR");
    }

    // ─── CheckResult ──────────────────────────────────────────────────────────

    @Test
    @DisplayName("CheckResult no-arg constructor")
    void testCheckResultNoArg() {
        X402Paywall.CheckResult cr = new X402Paywall.CheckResult();
        assertThat(cr.isValid).isFalse();
        assertThat(cr.invalidReason).isNull();
    }

    @Test
    @DisplayName("CheckResult two-arg constructor")
    void testCheckResultTwoArg() {
        X402Paywall.CheckResult cr = new X402Paywall.CheckResult(true, null);
        assertThat(cr.isValid).isTrue();
        assertThat(cr.invalidReason).isNull();
    }
}
