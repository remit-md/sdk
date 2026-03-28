package md.remit;

import md.remit.models.*;

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
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.HexFormat;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Java SDK acceptance tests: payDirect + escrow lifecycle on live Base Sepolia.
 *
 * <p>Run: ./gradlew acceptanceTest
 *
 * <p>Env vars (all optional):
 *   ACCEPTANCE_API_URL  - default: https://remit.md
 *   ACCEPTANCE_RPC_URL  - default: https://sepolia.base.org
 */
@Tag("acceptance")
class AcceptanceTest {

    // ─── Config ──────────────────────────────────────────────────────────────

    private static final String API_URL = envOr("ACCEPTANCE_API_URL", "https://testnet.remit.md");
    private static final String RPC_URL = envOr("ACCEPTANCE_RPC_URL", "https://sepolia.base.org");
    private static final String USDC_ADDRESS = "0x2d846325766921935f37d5b4478196d3ef93707c";
    private static final String FEE_WALLET = "0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38";
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
                .uri(URI.create(API_URL + "/api/v1/contracts"))
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

        // Sign (needToHash=false - digest is already the final hash)
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
        assertTrue(feeAfter >= feeBefore - 0.001, "fee wallet should not decrease");
        System.out.println("[ACCEPTANCE] fee wallet delta: " + (feeAfter - feeBefore));
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
        assertTrue(feeAfter >= feeBefore - 0.001, "fee wallet should not decrease");
        System.out.println("[ACCEPTANCE] fee wallet delta: " + (feeAfter - feeBefore));
    }

    // ─── Tab lifecycle ───────────────────────────────────────────────────────

    @Test
    void testTabLifecycle() throws Exception {
        TestWallet agent = createTestWallet();
        TestWallet provider = createTestWallet();
        fundWallet(agent, 100);

        double limit = 10.0;
        double chargeAmount = 2.0;
        int chargeUnits = (int) (chargeAmount * 1_000_000); // uint96 base units
        double fee = chargeAmount * 0.01; // 1% = $0.02
        double providerReceives = chargeAmount - fee; // $1.98

        double agentBefore = getUsdcBalance(agent.address());
        double providerBefore = getUsdcBalance(provider.address());
        double feeBefore = getFeeBalance();

        // Step 1: Open tab (agent, with permit for Tab contract)
        ContractAddresses contracts = fetchContracts();
        String tabContract = contracts.tab;

        long deadline = Instant.now().getEpochSecond() + 3600;
        long rawAmount = (long) ((limit + 1) * 1_000_000);
        PermitSignature permit = signUsdcPermit(
                agent.keyPair, agent.address(), tabContract,
                rawAmount, 0, deadline);

        Tab tab = agent.wallet.createTab(
                provider.address(),
                new BigDecimal("10.0"),
                new BigDecimal("0.1"),
                permit);
        assertNotNull(tab.id, "tab should have an id");
        assertFalse(tab.id.isBlank(), "tab id should not be blank");

        // Wait for on-chain lock (agent USDC moves to Tab contract)
        waitForBalanceChange(agent.address(), agentBefore);

        // Step 2: Provider charges $2 (off-chain with TabCharge EIP-712 sig)
        int callCount = 1;
        String chargeSig = provider.wallet.signTabCharge(
                tabContract, tab.id, chargeUnits, callCount);

        TabCharge charge = provider.wallet.chargeTab(
                tab.id,
                new BigDecimal("2.0"),
                new BigDecimal("2.0"),
                callCount,
                chargeSig);
        assertEquals(tab.id, charge.tabId, "charge should reference the tab");

        // Step 3: Close tab (agent, with provider's close signature on final state)
        String closeSig = provider.wallet.signTabCharge(
                tabContract, tab.id, chargeUnits, callCount);

        Transaction closeTx = agent.wallet.closeTab(
                tab.id,
                new BigDecimal("2.0"),
                closeSig);
        assertNotNull(closeTx.txHash, "close should return tx hash");
        assertTrue(closeTx.txHash.startsWith("0x"),
                "close tx hash should start with 0x, got: " + closeTx.txHash);

        // Verify balances
        double providerAfter = waitForBalanceChange(provider.address(), providerBefore);
        double feeAfter = getFeeBalance();
        double agentAfter = getUsdcBalance(agent.address());

        // Agent: locked $10, refunded $8, net change = -$2
        assertBalanceChange("agent", agentBefore, agentAfter, -chargeAmount);
        // Provider: received $2 minus 1% fee = $1.98
        assertBalanceChange("provider", providerBefore, providerAfter, providerReceives);
        // Fee wallet: received 1% of $2 = $0.02
        assertTrue(feeAfter >= feeBefore - 0.001, "fee wallet should not decrease");
        System.out.println("[ACCEPTANCE] fee wallet delta: " + (feeAfter - feeBefore));
    }

    // ─── Stream lifecycle ────────────────────────────────────────────────────

    @Test
    void testStreamLifecycle() throws Exception {
        TestWallet agent = createTestWallet();
        TestWallet provider = createTestWallet();
        fundWallet(agent, 100);

        double ratePerSecond = 0.1; // $0.10/s
        double maxTotal = 5.0;

        double agentBefore = getUsdcBalance(agent.address());
        double providerBefore = getUsdcBalance(provider.address());
        double feeBefore = getFeeBalance();

        // Step 1: Open stream with permit for Stream contract
        ContractAddresses contracts = fetchContracts();
        String streamContract = contracts.stream;

        long deadline = Instant.now().getEpochSecond() + 3600;
        long rawAmount = (long) ((maxTotal + 1) * 1_000_000);
        PermitSignature permit = signUsdcPermit(
                agent.keyPair, agent.address(), streamContract,
                rawAmount, 0, deadline);

        Stream stream = agent.wallet.createStream(
                provider.address(),
                new BigDecimal("0.1"),
                new BigDecimal("5.0"),
                permit);
        assertNotNull(stream.id, "stream should have an id");
        assertFalse(stream.id.isBlank(), "stream id should not be blank");

        // Wait for on-chain creation (agent locks maxTotal in Stream contract)
        waitForBalanceChange(agent.address(), agentBefore);

        // Step 2: Wait for accrual (~5 seconds)
        Thread.sleep(5_000);

        // Step 3: Close stream (payer only)
        Transaction closeTx = agent.wallet.closeStream(stream.id);
        assertNotNull(closeTx.txHash, "close stream should return tx hash");

        // Wait for settlement (provider balance should increase)
        double providerAfter = waitForBalanceChange(provider.address(), providerBefore);
        double feeAfter = getFeeBalance();
        double agentAfter = getUsdcBalance(agent.address());

        // Calculate actual changes
        double agentLoss = agentBefore - agentAfter;
        double providerGain = providerAfter - providerBefore;
        double feeGain = feeAfter - feeBefore;

        // Agent should have lost money (stream accrued), but <= maxTotal
        assertTrue(agentLoss > 0.05,
                "agent should have lost money from streaming, got loss=" + agentLoss);
        assertTrue(agentLoss <= maxTotal + 0.01,
                "agent loss should not exceed maxTotal ($" + maxTotal + "), got loss=" + agentLoss);

        // Provider should have received payout (accrued minus 1% fee)
        assertTrue(providerGain > 0.04,
                "provider should have received payout, got gain=" + providerGain);

        // Fee wallet should not decrease
        assertTrue(feeGain >= 0,
                "fee wallet should not decrease, got change=" + feeGain);

        // Conservation of funds: agent loss ~ provider gain + fee
        double conservationDiff = Math.abs(agentLoss - (providerGain + feeGain));
        assertTrue(conservationDiff < 0.01,
                String.format("conservation violated: agent lost %.6f, provider+fee gained %.6f, diff=%.6f",
                        agentLoss, providerGain + feeGain, conservationDiff));
    }

    // ─── Bounty lifecycle ────────────────────────────────────────────────────

    @Test
    void testBountyLifecycle() throws Exception {
        TestWallet poster = createTestWallet();
        TestWallet provider = createTestWallet();
        fundWallet(poster, 100);

        double amount = 5.0;
        double fee = amount * 0.01; // 1% = $0.05
        double providerReceives = amount - fee; // $4.95

        double posterBefore = getUsdcBalance(poster.address());
        double providerBefore = getUsdcBalance(provider.address());
        double feeBefore = getFeeBalance();

        // Step 1: Post bounty (auto-permit)
        long deadlineTs = Instant.now().getEpochSecond() + 3600;

        // Use auto-permit (SDK signs internally)
        Bounty bounty = poster.wallet.createBounty(
                new BigDecimal("5.0"),
                "java-bounty-acceptance-test",
                deadlineTs);
        assertNotNull(bounty.id, "bounty should have an id");
        assertFalse(bounty.id.isBlank(), "bounty id should not be blank");

        // Wait for on-chain bounty creation (poster USDC locked in Bounty contract)
        waitForBalanceChange(poster.address(), posterBefore);

        // Step 2: Provider submits evidence
        String evidenceHash = "0x" + "ab".repeat(32);
        Transaction submitTx = provider.wallet.submitBounty(bounty.id, evidenceHash);
        assertNotNull(submitTx.id, "submission should have an id");

        // Wait for submission to be recorded
        Thread.sleep(10_000);

        // Step 3: Poster awards to the submission
        Transaction awardTx = poster.wallet.awardBounty(bounty.id, 1);
        assertNotNull(awardTx.txHash, "award should return tx hash");

        // Verify balances
        double providerAfter = waitForBalanceChange(provider.address(), providerBefore);
        double feeAfter = getFeeBalance();
        double posterAfter = getUsdcBalance(poster.address());

        // Poster: lost $5 (bounty amount)
        assertBalanceChange("poster", posterBefore, posterAfter, -amount);
        // Provider: received $5 minus 1% fee = $4.95
        assertBalanceChange("provider", providerBefore, providerAfter, providerReceives);
        // Fee wallet: received 1% of $5 = $0.05
        assertTrue(feeAfter >= feeBefore - 0.001, "fee wallet should not decrease");
        System.out.println("[ACCEPTANCE] fee wallet delta: " + (feeAfter - feeBefore));
    }

    // ─── Deposit lifecycle ───────────────────────────────────────────────────

    @Test
    void testDepositLifecycle() throws Exception {
        TestWallet agent = createTestWallet();
        TestWallet provider = createTestWallet();
        fundWallet(agent, 100);

        double amount = 5.0;

        double agentBefore = getUsdcBalance(agent.address());
        double providerBefore = getUsdcBalance(provider.address());
        double feeBefore = getFeeBalance();

        // Step 1: Place deposit with permit for Deposit contract
        ContractAddresses contracts = fetchContracts();
        String depositContract = contracts.deposit;

        long deadline = Instant.now().getEpochSecond() + 3600;
        long rawAmount = (long) ((amount + 1) * 1_000_000);
        PermitSignature permit = signUsdcPermit(
                agent.keyPair, agent.address(), depositContract,
                rawAmount, 0, deadline);

        Deposit deposit = agent.wallet.lockDeposit(
                provider.address(),
                new BigDecimal("5.0"),
                3600, // 1 hour
                permit);
        assertNotNull(deposit.id, "deposit should have an id");
        assertFalse(deposit.id.isBlank(), "deposit id should not be blank");

        // Wait for on-chain deposit lock
        double agentMid = waitForBalanceChange(agent.address(), agentBefore);
        assertBalanceChange("agent locked", agentBefore, agentMid, -amount);

        // Step 2: Provider returns the deposit
        Transaction returnTx = provider.wallet.returnDeposit(deposit.id);
        assertNotNull(returnTx.txHash, "return deposit should return tx hash");

        // Wait for return settlement (agent gets full refund)
        double agentAfter = waitForBalanceChange(agent.address(), agentMid);
        double providerAfter = getUsdcBalance(provider.address());
        double feeAfter = getFeeBalance();

        // Agent: full refund -- net change ~ $0
        assertBalanceChange("agent net", agentBefore, agentAfter, 0);
        // Provider: unchanged
        assertBalanceChange("provider", providerBefore, providerAfter, 0);
        // Fee wallet: unchanged (deposits have no fee)
        assertBalanceChange("fee wallet", feeBefore, feeAfter, 0);
    }

    // ─── x402 auto-pay ──────────────────────────────────────────────────────

    @Test
    void testX402AutoPay() throws Exception {
        TestWallet agent = createTestWallet();
        fundWallet(agent, 100);

        // Fetch contract addresses for the paywall header
        ContractAddresses contracts = fetchContracts();

        // Start a local paywall server that returns 402 first, then 200 on retry
        var server = com.sun.net.httpserver.HttpServer.create(
                new java.net.InetSocketAddress("127.0.0.1", 0), 0);
        int port = server.getAddress().getPort();
        String serverUrl = "http://127.0.0.1:" + port;

        server.createContext("/test-resource", exchange -> {
            String paymentSig = exchange.getRequestHeaders().getFirst("PAYMENT-SIGNATURE");

            if (paymentSig == null) {
                // First request: return 402
                var paymentRequired = new java.util.LinkedHashMap<String, Object>();
                paymentRequired.put("scheme", "exact");
                paymentRequired.put("network", "eip155:84532");
                paymentRequired.put("amount", "100000"); // $0.10 USDC
                paymentRequired.put("asset", contracts.usdc);
                paymentRequired.put("payTo", contracts.router);
                paymentRequired.put("maxTimeoutSeconds", 60);
                paymentRequired.put("resource", "/test-resource");
                paymentRequired.put("description", "x402 acceptance test");
                paymentRequired.put("mimeType", "text/plain");

                var mapper = new com.fasterxml.jackson.databind.ObjectMapper();
                String json = mapper.writeValueAsString(paymentRequired);
                String encoded = Base64.getEncoder().encodeToString(json.getBytes(StandardCharsets.UTF_8));

                exchange.getResponseHeaders().add("PAYMENT-REQUIRED", encoded);
                exchange.getResponseHeaders().add("Content-Type", "text/plain");
                exchange.sendResponseHeaders(402, 16);
                exchange.getResponseBody().write("Payment Required".getBytes());
                exchange.getResponseBody().close();
            } else {
                // Second request: validate PAYMENT-SIGNATURE structure
                try {
                    String decoded = new String(Base64.getDecoder().decode(paymentSig), StandardCharsets.UTF_8);
                    var mapper = new com.fasterxml.jackson.databind.ObjectMapper();
                    @SuppressWarnings("unchecked")
                    var payload = mapper.readValue(decoded, java.util.Map.class);

                    assertEquals("exact", payload.get("scheme"));
                    assertEquals("eip155:84532", payload.get("network"));

                    @SuppressWarnings("unchecked")
                    var inner = (java.util.Map<String, Object>) payload.get("payload");
                    assertNotNull(inner.get("signature"));
                    assertTrue(inner.get("signature").toString().startsWith("0x"));

                    @SuppressWarnings("unchecked")
                    var auth = (java.util.Map<String, Object>) inner.get("authorization");
                    assertEquals(agent.address().toLowerCase(), auth.get("from").toString().toLowerCase());
                    assertEquals("100000", auth.get("value"));

                    byte[] resp = "paid content".getBytes();
                    exchange.getResponseHeaders().add("Content-Type", "text/plain");
                    exchange.sendResponseHeaders(200, resp.length);
                    exchange.getResponseBody().write(resp);
                    exchange.getResponseBody().close();
                } catch (Exception e) {
                    byte[] err = ("Invalid payment: " + e.getMessage()).getBytes();
                    exchange.sendResponseHeaders(400, err.length);
                    exchange.getResponseBody().write(err);
                    exchange.getResponseBody().close();
                }
            }
        });

        server.start();
        try {
            // x402 auto-pay
            X402Client x402 = new X402Client(agent.wallet, 0.20);
            X402Client.X402Response response = x402.fetch(serverUrl + "/test-resource");

            assertEquals(200, response.response().statusCode(),
                    "should get 200 after auto-payment, got " + response.response().statusCode());
            assertEquals("paid content", response.response().body(),
                    "should receive paid content");

            // Verify last payment metadata (V2 fields)
            assertNotNull(response.lastPayment(), "lastPayment should be set");
            assertEquals("exact", response.lastPayment().get("scheme"));
            assertEquals("100000", response.lastPayment().get("amount"));
            assertEquals("/test-resource", response.lastPayment().get("resource"));
            assertEquals("x402 acceptance test", response.lastPayment().get("description"));
            assertEquals("text/plain", response.lastPayment().get("mimeType"));
        } finally {
            server.stop(0);
        }
    }
}
