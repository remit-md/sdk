package md.remit;

import md.remit.models.ContractAddresses;
import md.remit.models.Escrow;
import md.remit.models.PermitSignature;
import md.remit.models.Transaction;

import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;
import org.web3j.crypto.ECKeyPair;
import org.web3j.crypto.Hash;
import org.web3j.crypto.Keys;
import org.web3j.crypto.Sign;
import org.web3j.utils.Numeric;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.time.Instant;
import java.util.HexFormat;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Java SDK acceptance tests: payDirect + escrow lifecycle on live Base Sepolia.
 *
 * <p>Run: ./gradlew acceptanceTest
 *
 * <p>Env vars (all optional):
 *   ACCEPTANCE_API_URL  — default: https://remit.md
 *   ACCEPTANCE_RPC_URL  — default: https://sepolia.base.org
 */
@Tag("acceptance")
class AcceptanceTest {

    // ─── Config ──────────────────────────────────────────────────────────────

    private static final String API_URL = envOr("ACCEPTANCE_API_URL", "https://remit.md");
    private static final String RPC_URL = envOr("ACCEPTANCE_RPC_URL", "https://sepolia.base.org");
    private static final String USDC_ADDRESS = "0x142aD61B8d2edD6b3807D9266866D97C35Ee0317";
    private static final String FEE_WALLET = "0xd3f721BDF92a2bB5Dd8d2FE2AFC03aFE5629B420";
    private static final long CHAIN_ID = 84532L;

    private static final HttpClient HTTP = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();

    private static String envOr(String key, String fallback) {
        String v = System.getenv(key);
        return (v != null && !v.isBlank()) ? v : fallback;
    }

    // ─── Test wallet ─────────────────────────────────────────────────────────

    private record TestWallet(Wallet wallet, ECKeyPair keyPair) {
        String address() { return wallet.address(); }
    }

    private static TestWallet createTestWallet() throws Exception {
        ECKeyPair keyPair = Keys.createEcKeyPair();
        String hexKey = "0x" + Numeric.toHexStringNoPrefixZeroPadded(keyPair.getPrivateKey(), 64);

        ContractAddresses contracts = fetchContracts();
        Wallet wallet = RemitMd.withKey(hexKey)
                .testnet(true)
                .baseUrl(API_URL)
                .routerAddress(contracts.router)
                .build();

        return new TestWallet(wallet, keyPair);
    }

    // ─── Contract discovery (unauthenticated) ───────────────────────────────

    private static volatile ContractAddresses cachedContracts;

    private static ContractAddresses fetchContracts() throws Exception {
        if (cachedContracts != null) return cachedContracts;
        HttpRequest req = HttpRequest.newBuilder()
                .uri(URI.create(API_URL + "/api/v0/contracts"))
                .GET()
                .timeout(Duration.ofSeconds(15))
                .build();
        HttpResponse<String> resp = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
        assertEquals(200, resp.statusCode(), "GET /contracts: " + resp.body());
        var mapper = new com.fasterxml.jackson.databind.ObjectMapper()
                .configure(com.fasterxml.jackson.databind.DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);
        cachedContracts = mapper.readValue(resp.body(), ContractAddresses.class);
        assertNotNull(cachedContracts.router, "/contracts returned empty router");
        return cachedContracts;
    }

    // ─── On-chain balance via RPC ───────────────────────────────────────────

    private static double getUsdcBalance(String address) throws Exception {
        String hex = address.toLowerCase().replace("0x", "");
        String padded = "0".repeat(64 - hex.length()) + hex;
        String callData = "0x70a08231" + padded;

        String body = String.format(
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"%s\",\"data\":\"%s\"},\"latest\"]}",
                USDC_ADDRESS, callData);

        HttpRequest req = HttpRequest.newBuilder()
                .uri(URI.create(RPC_URL))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .timeout(Duration.ofSeconds(15))
                .build();

        HttpResponse<String> resp = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
        var mapper = new com.fasterxml.jackson.databind.ObjectMapper();
        var node = mapper.readTree(resp.body());
        if (node.has("error")) {
            fail("RPC error: " + node.get("error"));
        }
        String resultHex = node.get("result").asText("0x0").replace("0x", "");
        if (resultHex.isEmpty()) resultHex = "0";
        BigInteger raw = new BigInteger(resultHex, 16);
        return raw.doubleValue() / 1_000_000.0;
    }

    private static double getFeeBalance() throws Exception {
        return getUsdcBalance(FEE_WALLET);
    }

    private static double waitForBalanceChange(String address, double before) throws Exception {
        long deadline = System.currentTimeMillis() + 30_000;
        while (System.currentTimeMillis() < deadline) {
            double current = getUsdcBalance(address);
            if (Math.abs(current - before) > 0.0001) return current;
            Thread.sleep(2_000);
        }
        return getUsdcBalance(address);
    }

    private static void assertBalanceChange(String label, double before, double after, double expected) {
        double actual = after - before;
        double tolerance = Math.max(Math.abs(expected) * 0.001, 0.02);
        assertTrue(Math.abs(actual - expected) <= tolerance,
                String.format("%s: expected delta %.6f, got %.6f (before=%.6f, after=%.6f)",
                        label, expected, actual, before, after));
    }

    // ─── Funding ────────────────────────────────────────────────────────────

    private static void fundWallet(TestWallet w, double amount) throws Exception {
        w.wallet.mint(amount);
        waitForBalanceChange(w.address(), 0);
    }

    // ─── EIP-2612 Permit Signing ────────────────────────────────────────────

    private static PermitSignature signUsdcPermit(
            ECKeyPair keyPair,
            String owner,
            String spender,
            long value,
            long nonce,
            long deadline) {

        // Domain separator: EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
        byte[] domainTypeHash = Hash.sha3(
                "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".getBytes());
        byte[] nameHash = Hash.sha3("USD Coin".getBytes());
        byte[] versionHash = Hash.sha3("2".getBytes());

        byte[] domainData = concat(
                domainTypeHash,
                nameHash,
                versionHash,
                toUint256(CHAIN_ID),
                addressToBytes32(USDC_ADDRESS));
        byte[] domainSep = Hash.sha3(domainData);

        // Permit struct hash
        byte[] permitTypeHash = Hash.sha3(
                "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)".getBytes());

        byte[] structData = concat(
                permitTypeHash,
                addressToBytes32(owner),
                addressToBytes32(spender),
                toUint256(value),
                toUint256(nonce),
                toUint256(deadline));
        byte[] structHash = Hash.sha3(structData);

        // EIP-712 digest: "\x19\x01" || domainSeparator || structHash
        byte[] finalData = new byte[2 + 32 + 32];
        finalData[0] = 0x19;
        finalData[1] = 0x01;
        System.arraycopy(domainSep, 0, finalData, 2, 32);
        System.arraycopy(structHash, 0, finalData, 34, 32);
        byte[] digest = Hash.sha3(finalData);

        // Sign (needToHash=false — digest is already the final hash)
        Sign.SignatureData sig = Sign.signMessage(digest, keyPair, false);

        int v = sig.getV()[0] & 0xFF;
        String r = "0x" + HexFormat.of().formatHex(sig.getR());
        String s = "0x" + HexFormat.of().formatHex(sig.getS());

        return new PermitSignature(value, deadline, v, r, s);
    }

    private static byte[] toUint256(long value) {
        BigInteger bi = BigInteger.valueOf(value);
        if (value < 0) {
            // Unsigned interpretation
            bi = new BigInteger(Long.toUnsignedString(value));
        }
        byte[] b = bi.toByteArray();
        byte[] result = new byte[32];
        int start = (b.length > 1 && b[0] == 0) ? 1 : 0;
        int len = b.length - start;
        System.arraycopy(b, start, result, 32 - len, len);
        return result;
    }

    private static byte[] addressToBytes32(String address) {
        String hex = address.startsWith("0x") ? address.substring(2) : address;
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

    // ─── Tests ──────────────────────────────────────────────────────────────

    @Test
    void payDirectWithPermit() throws Exception {
        TestWallet agent = createTestWallet();
        TestWallet provider = createTestWallet();
        fundWallet(agent, 100);

        double amount = 1.0;
        double fee = 0.01;
        double providerReceives = amount - fee;

        double agentBefore = getUsdcBalance(agent.address());
        double providerBefore = getUsdcBalance(provider.address());
        double feeBefore = getFeeBalance();

        // Sign EIP-2612 permit for Router
        ContractAddresses contracts = fetchContracts();
        long deadline = Instant.now().getEpochSecond() + 3600;
        PermitSignature permit = signUsdcPermit(
                agent.keyPair, agent.address(), contracts.router,
                2_000_000, // $2 USDC in base units
                0,         // nonce 0 (fresh wallet)
                deadline);

        Transaction tx = agent.wallet.pay(
                provider.address(),
                new BigDecimal("1.0"),
                "java-sdk-acceptance",
                permit);
        assertNotNull(tx.txHash, "tx_hash should not be null");
        assertTrue(tx.txHash.startsWith("0x"), "expected tx hash 0x prefix, got: " + tx.txHash);

        double agentAfter = waitForBalanceChange(agent.address(), agentBefore);
        double providerAfter = getUsdcBalance(provider.address());
        double feeAfter = getFeeBalance();

        assertBalanceChange("agent", agentBefore, agentAfter, -amount);
        assertBalanceChange("provider", providerBefore, providerAfter, providerReceives);
        assertBalanceChange("fee wallet", feeBefore, feeAfter, fee);
    }

    @Test
    void escrowLifecycle() throws Exception {
        TestWallet agent = createTestWallet();
        TestWallet provider = createTestWallet();
        fundWallet(agent, 100);

        double amount = 5.0;
        double fee = amount * 0.01;
        double providerReceives = amount - fee;

        double agentBefore = getUsdcBalance(agent.address());
        double providerBefore = getUsdcBalance(provider.address());
        double feeBefore = getFeeBalance();

        // Sign EIP-2612 permit for Escrow contract
        ContractAddresses contracts = fetchContracts();
        long deadline = Instant.now().getEpochSecond() + 3600;
        PermitSignature permit = signUsdcPermit(
                agent.keyPair, agent.address(), contracts.escrow,
                6_000_000, // $6 USDC in base units
                0,         // nonce 0
                deadline);

        Escrow escrow = agent.wallet.createEscrow(
                provider.address(),
                new BigDecimal("5.0"),
                permit);
        assertNotNull(escrow.id, "escrow should have an id");
        assertFalse(escrow.id.isBlank(), "escrow id should not be blank");

        // Wait for on-chain lock
        waitForBalanceChange(agent.address(), agentBefore);

        // Provider claims start
        provider.wallet.claimStart(escrow.id);
        Thread.sleep(5_000);

        // Agent releases
        agent.wallet.releaseEscrow(escrow.id);

        // Verify balances
        double providerAfter = waitForBalanceChange(provider.address(), providerBefore);
        double feeAfter = getFeeBalance();
        double agentAfter = getUsdcBalance(agent.address());

        assertBalanceChange("agent", agentBefore, agentAfter, -amount);
        assertBalanceChange("provider", providerBefore, providerAfter, providerReceives);
        assertBalanceChange("fee wallet", feeBefore, feeAfter, fee);
    }
}
