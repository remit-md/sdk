package md.remit;

import md.remit.models.*;

import org.junit.jupiter.api.*;

import org.web3j.crypto.ECKeyPair;
import org.web3j.crypto.Keys;
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
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Java SDK acceptance tests: 9 payment flows with 2 shared wallets on live Base Sepolia.
 *
 * <p>Creates agent (payer) + provider (payee) wallets once, mints 100 USDC
 * to agent, then runs all 9 flows sequentially with small amounts.
 *
 * <p>Flows: direct, escrow, tab, stream, bounty, deposit, x402Prepare, ap2Discovery, ap2Payment.
 *
 * <p>Run: ./gradlew acceptanceTest
 *
 * <p>Env vars (all optional):
 *   ACCEPTANCE_API_URL  - default: https://testnet.remit.md
 *   ACCEPTANCE_RPC_URL  - default: https://sepolia.base.org
 */
@Tag("acceptance")
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class AcceptanceTest {

    // ─── Config ──────────────────────────────────────────────────────────────

    private static final String API_URL = envOr("ACCEPTANCE_API_URL", "https://testnet.remit.md");
    private static final String RPC_URL = envOr("ACCEPTANCE_RPC_URL", "https://sepolia.base.org");
    private static final HttpClient HTTP = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();

    private static String envOr(String key, String fallback) {
        String v = System.getenv(key);
        return (v != null && !v.isBlank()) ? v : fallback;
    }

    // ─── Shared wallets (created once, reused across all tests) ──────────

    private record TestWallet(Wallet wallet, ECKeyPair keyPair) {
        String address() { return wallet.address(); }
    }

    private static TestWallet agent;
    private static TestWallet provider;

    @BeforeAll
    static void setupWallets() throws Exception {
        agent = createTestWallet("agent");
        provider = createTestWallet("provider");
        fundWallet(agent, 100);
    }

    private static TestWallet createTestWallet(String label) throws Exception {
        ECKeyPair keyPair = Keys.createEcKeyPair();
        String hexKey = "0x" + Numeric.toHexStringNoPrefixZeroPadded(keyPair.getPrivateKey(), 64);

        ContractAddresses contracts = fetchContracts();
        Wallet wallet = RemitMd.withKey(hexKey)
                .testnet(true)
                .baseUrl(API_URL)
                .routerAddress(contracts.router)
                .build();

        System.out.println("[ACCEPTANCE] " + label + " wallet: " + wallet.address() + " (chain=84532)");
        return new TestWallet(wallet, keyPair);
    }

    private static void logTx(String flow, String step, String txHash) {
        System.out.println("[ACCEPTANCE] " + flow + " | " + step + " | tx=" + txHash
                + " | https://sepolia.basescan.org/tx/" + txHash);
    }

    // ─── Contract discovery (unauthenticated, cached) ────────────────────

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

    // ─── On-chain balance via RPC ────────────────────────────────────────

    private static double getUsdcBalance(String address) throws Exception {
        ContractAddresses contracts = fetchContracts();
        String usdcAddr = contracts.usdc;
        String hex = address.toLowerCase().replace("0x", "");
        String padded = "0".repeat(64 - hex.length()) + hex;
        String callData = "0x70a08231" + padded;

        String body = String.format(
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"%s\",\"data\":\"%s\"},\"latest\"]}",
                usdcAddr, callData);

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

    // ─── Funding ─────────────────────────────────────────────────────────

    private static void fundWallet(TestWallet w, double amount) throws Exception {
        System.out.println("[ACCEPTANCE] mint: " + amount + " USDC -> " + w.address());
        MintResponse mintResp = w.wallet.mint(amount);
        if (mintResp.txHash != null) logTx("mint", "fund", mintResp.txHash);
        waitForBalanceChange(w.address(), 0);
    }

    // ─── Flow 1: Direct ──────────────────────────────────────────────────

    @Test
    @Order(1)
    void test01Direct() throws Exception {
        double amount = 1.0;

        double agentBefore = getUsdcBalance(agent.address());
        double providerBefore = getUsdcBalance(provider.address());

        PermitSignature permit = agent.wallet.signPermit("direct", new BigDecimal("1.0"));

        Transaction tx = agent.wallet.pay(
                provider.address(),
                new BigDecimal("1.0"),
                "acceptance-direct",
                permit);
        assertNotNull(tx.txHash, "tx_hash should not be null");
        assertTrue(tx.txHash.startsWith("0x"), "expected tx hash 0x prefix, got: " + tx.txHash);
        logTx("direct", amount + " USDC " + agent.address() + "->" + provider.address(), tx.txHash);

        double agentAfter = waitForBalanceChange(agent.address(), agentBefore);
        double providerAfter = getUsdcBalance(provider.address());

        assertBalanceChange("agent", agentBefore, agentAfter, -amount);
        assertBalanceChange("provider", providerBefore, providerAfter, amount * 0.99);
    }

    // ─── Flow 2: Escrow ──────────────────────────────────────────────────

    @Test
    @Order(2)
    void test02Escrow() throws Exception {
        double amount = 2.0;

        double agentBefore = getUsdcBalance(agent.address());
        double providerBefore = getUsdcBalance(provider.address());

        PermitSignature permit = agent.wallet.signPermit("escrow", new BigDecimal("2.0"));

        Escrow escrow = agent.wallet.createEscrow(
                provider.address(),
                new BigDecimal("2.0"),
                "acceptance-escrow",
                Duration.ofHours(1),
                null, null,
                permit);
        assertNotNull(escrow.id, "escrow should have an id");
        assertFalse(escrow.id.isBlank(), "escrow id should not be blank");
        System.out.println("[ACCEPTANCE] escrow | fund " + amount + " USDC | id=" + escrow.id);

        waitForBalanceChange(agent.address(), agentBefore);

        Transaction claimTx = provider.wallet.claimStart(escrow.id);
        if (claimTx.txHash != null) logTx("escrow", "claimStart", claimTx.txHash);
        Thread.sleep(5_000);

        Transaction releaseTx = agent.wallet.releaseEscrow(escrow.id);
        if (releaseTx.txHash != null) logTx("escrow", "release", releaseTx.txHash);

        double providerAfter = waitForBalanceChange(provider.address(), providerBefore);
        double agentAfter = getUsdcBalance(agent.address());

        assertBalanceChange("agent", agentBefore, agentAfter, -amount);
        assertBalanceChange("provider", providerBefore, providerAfter, amount * 0.99);
    }

    // ─── Flow 3: Tab ─────────────────────────────────────────────────────

    @Test
    @Order(3)
    void test03Tab() throws Exception {
        double limit = 5.0;
        double chargeAmount = 1.0;
        int chargeUnits = (int) (chargeAmount * 1_000_000);

        double agentBefore = getUsdcBalance(agent.address());
        double providerBefore = getUsdcBalance(provider.address());

        ContractAddresses contracts = fetchContracts();
        String tabContract = contracts.tab;

        PermitSignature permit = agent.wallet.signPermit("tab", new BigDecimal("5.0"));

        Tab tab = agent.wallet.createTab(
                provider.address(),
                new BigDecimal("5.0"),
                new BigDecimal("0.1"),
                permit);
        assertNotNull(tab.id, "tab should have an id");
        assertFalse(tab.id.isBlank(), "tab id should not be blank");
        System.out.println("[ACCEPTANCE] tab | open limit=" + limit + " | id=" + tab.id);

        waitForBalanceChange(agent.address(), agentBefore);

        int callCount = 1;
        String chargeSig = provider.wallet.signTabCharge(
                tabContract, tab.id, chargeUnits, callCount);

        TabCharge charge = provider.wallet.chargeTab(
                tab.id,
                new BigDecimal("1.0"),
                new BigDecimal("1.0"),
                callCount,
                chargeSig);
        assertEquals(tab.id, charge.tabId, "charge should reference the tab");

        String closeSig = provider.wallet.signTabCharge(
                tabContract, tab.id, chargeUnits, callCount);

        Transaction closeTx = agent.wallet.closeTab(
                tab.id,
                new BigDecimal("1.0"),
                closeSig);
        assertNotNull(closeTx.txHash, "close should return tx hash");
        assertTrue(closeTx.txHash.startsWith("0x"),
                "close tx hash should start with 0x, got: " + closeTx.txHash);
        logTx("tab", "close", closeTx.txHash);

        double providerAfter = waitForBalanceChange(provider.address(), providerBefore);
        double agentAfter = getUsdcBalance(agent.address());

        assertBalanceChange("agent", agentBefore, agentAfter, -chargeAmount);
        assertBalanceChange("provider", providerBefore, providerAfter, chargeAmount * 0.99);
    }

    // ─── Flow 4: Stream ──────────────────────────────────────────────────

    @Test
    @Order(4)
    void test04Stream() throws Exception {
        double maxTotal = 2.0;

        double agentBefore = getUsdcBalance(agent.address());
        double providerBefore = getUsdcBalance(provider.address());

        PermitSignature permit = agent.wallet.signPermit("stream", new BigDecimal("2.0"));

        Stream stream = agent.wallet.createStream(
                provider.address(),
                new BigDecimal("0.1"),
                new BigDecimal("2.0"),
                permit);
        assertNotNull(stream.id, "stream should have an id");
        assertFalse(stream.id.isBlank(), "stream id should not be blank");
        System.out.println("[ACCEPTANCE] stream | open rate=0.1/s max=" + maxTotal + " | id=" + stream.id);

        waitForBalanceChange(agent.address(), agentBefore);
        Thread.sleep(5_000);

        Transaction closeTx = agent.wallet.closeStream(stream.id);
        assertNotNull(closeTx.txHash, "close stream should return tx hash");
        logTx("stream", "close", closeTx.txHash);

        double providerAfter = waitForBalanceChange(provider.address(), providerBefore);
        double agentAfter = getUsdcBalance(agent.address());

        double agentLoss = agentBefore - agentAfter;
        assertTrue(agentLoss > 0.05,
                "agent should have lost money from streaming, got loss=" + agentLoss);
        assertTrue(agentLoss <= maxTotal + 0.01,
                "agent loss should not exceed maxTotal ($" + maxTotal + "), got loss=" + agentLoss);

        double providerGain = providerAfter - providerBefore;
        assertTrue(providerGain > 0.04,
                "provider should have received payout, got gain=" + providerGain);
    }

    // ─── Flow 5: Bounty ──────────────────────────────────────────────────

    @Test
    @Order(5)
    void test05Bounty() throws Exception {
        double amount = 2.0;
        long deadlineTs = Instant.now().getEpochSecond() + 3600;

        double agentBefore = getUsdcBalance(agent.address());
        double providerBefore = getUsdcBalance(provider.address());

        PermitSignature permit = agent.wallet.signPermit("bounty", new BigDecimal("2.0"));

        Bounty bounty = agent.wallet.createBounty(
                new BigDecimal("2.0"),
                "acceptance-bounty",
                deadlineTs,
                permit);
        assertNotNull(bounty.id, "bounty should have an id");
        assertFalse(bounty.id.isBlank(), "bounty id should not be blank");
        System.out.println("[ACCEPTANCE] bounty | post " + amount + " USDC | id=" + bounty.id);

        waitForBalanceChange(agent.address(), agentBefore);

        String evidence = "0x" + "ab".repeat(32);
        Transaction submitTx = provider.wallet.submitBounty(bounty.id, evidence);
        assertNotNull(submitTx.id, "submission should have an id");
        System.out.println("[ACCEPTANCE] bounty | submit | id=" + bounty.id);

        // Retry award up to 15 times (Ponder indexer lag)
        Transaction awarded = null;
        for (int attempt = 0; attempt < 15; attempt++) {
            Thread.sleep(3_000);
            try {
                awarded = agent.wallet.awardBounty(bounty.id, 1);
                break;
            } catch (Exception e) {
                if (attempt < 14) {
                    System.out.println("[ACCEPTANCE] bounty award retry " + (attempt + 1) + ": " + e.getMessage());
                } else {
                    throw e;
                }
            }
        }
        assertNotNull(awarded, "award should succeed");
        assertNotNull(awarded.txHash, "award should return tx hash");
        logTx("bounty", "award", awarded.txHash);

        double providerAfter = waitForBalanceChange(provider.address(), providerBefore);
        double agentAfter = getUsdcBalance(agent.address());

        assertBalanceChange("agent", agentBefore, agentAfter, -amount);
        assertBalanceChange("provider", providerBefore, providerAfter, amount * 0.99);
    }

    // ─── Flow 6: Deposit ─────────────────────────────────────────────────

    @Test
    @Order(6)
    void test06Deposit() throws Exception {
        double amount = 2.0;

        double agentBefore = getUsdcBalance(agent.address());

        PermitSignature permit = agent.wallet.signPermit("deposit", new BigDecimal("2.0"));

        Deposit deposit = agent.wallet.lockDeposit(
                provider.address(),
                new BigDecimal("2.0"),
                3600,
                permit);
        assertNotNull(deposit.id, "deposit should have an id");
        assertFalse(deposit.id.isBlank(), "deposit id should not be blank");
        System.out.println("[ACCEPTANCE] deposit | place " + amount + " USDC | id=" + deposit.id);

        double agentMid = waitForBalanceChange(agent.address(), agentBefore);
        assertBalanceChange("agent locked", agentBefore, agentMid, -amount);

        Transaction returnTx = provider.wallet.returnDeposit(deposit.id);
        assertNotNull(returnTx.txHash, "return deposit should return tx hash");
        logTx("deposit", "return", returnTx.txHash);

        double agentAfter = waitForBalanceChange(agent.address(), agentMid);
        assertBalanceChange("agent refund", agentBefore, agentAfter, 0);
    }

    // ─── Flow 7: x402 (via /x402/prepare — no local HTTP server) ────────

    @Test
    @Order(7)
    void test07X402Prepare() throws Exception {
        ContractAddresses contracts = fetchContracts();

        var paymentRequired = new java.util.LinkedHashMap<String, Object>();
        paymentRequired.put("scheme", "exact");
        paymentRequired.put("network", "eip155:84532");
        paymentRequired.put("amount", "100000");
        paymentRequired.put("asset", contracts.usdc);
        paymentRequired.put("payTo", contracts.router);
        paymentRequired.put("maxTimeoutSeconds", 60);

        var mapper = new com.fasterxml.jackson.databind.ObjectMapper();
        String json = mapper.writeValueAsString(paymentRequired);
        String encoded = Base64.getEncoder().encodeToString(json.getBytes(StandardCharsets.UTF_8));

        // POST /x402/prepare using the wallet's authenticated API client
        @SuppressWarnings("unchecked")
        Map<String, Object> data = agent.wallet.apiClient().post(
                "/api/v1/x402/prepare",
                Map.of("payment_required", encoded, "payer", agent.address()),
                Map.class);

        assertNotNull(data.get("hash"), "x402/prepare missing hash: " + data);
        String hash = data.get("hash").toString();
        assertTrue(hash.startsWith("0x"), "hash should start with 0x");
        assertEquals(66, hash.length(), "hash should be 0x + 64 hex chars");
        assertNotNull(data.get("from"), "x402/prepare missing from");
        assertNotNull(data.get("to"), "x402/prepare missing to");
        assertNotNull(data.get("value"), "x402/prepare missing value");

        System.out.println("[ACCEPTANCE] x402 | prepare | hash=" + hash.substring(0, 18) + "..."
                + " | from=" + data.get("from").toString().substring(0, 10) + "...");
    }

    // ─── Flow 8: AP2 Discovery ───────────────────────────────────────────

    @Test
    @Order(8)
    void test08Ap2Discovery() throws Exception {
        A2A.AgentCard card = A2A.AgentCard.discover(API_URL).join();

        assertNotNull(card.name(), "agent card should have a name");
        assertFalse(card.name().isBlank(), "agent card name should not be blank");
        assertNotNull(card.url(), "agent card should have a URL");
        assertNotNull(card.skills(), "agent card should have skills");
        assertFalse(card.skills().isEmpty(), "agent card should have at least one skill");
        assertNotNull(card.x402(), "agent card should have x402 config");

        System.out.println("[ACCEPTANCE] ap2-discovery | name=" + card.name()
                + " | skills=" + card.skills().size()
                + " | x402=" + (card.x402() != null));
    }

    // ─── Flow 9: AP2 Payment ─────────────────────────────────────────────

    @Test
    @Order(9)
    void test09Ap2Payment() throws Exception {
        double amount = 1.0;

        double agentBefore = getUsdcBalance(agent.address());
        double providerBefore = getUsdcBalance(provider.address());

        A2A.AgentCard card = A2A.AgentCard.discover(API_URL).join();

        PermitSignature permit = agent.wallet.signPermit("direct", new BigDecimal("1.0"));

        A2A.Client a2a = A2A.Client.fromCard(card, agent.wallet.signer(), agent.wallet.chainId(), "");
        A2A.Task task = a2a.send(new A2A.SendOptions(
                provider.address(), amount, "acceptance-ap2", null, permit));

        assertEquals("completed", task.status().state(),
                "A2A task failed: state=" + task.status().state());
        String txHash = A2A.getTaskTxHash(task);
        assertNotNull(txHash, "A2A task should have txHash in artifacts");
        assertTrue(txHash.startsWith("0x"), "txHash should start with 0x");
        logTx("ap2-payment", amount + " USDC via A2A", txHash);

        double agentAfter = waitForBalanceChange(agent.address(), agentBefore);
        double providerAfter = getUsdcBalance(provider.address());

        assertBalanceChange("agent", agentBefore, agentAfter, -amount);
        assertBalanceChange("provider", providerBefore, providerAfter, amount * 0.99);
    }
}
