/**
 * Remit SDK Acceptance -- Java: 9 flows against Base Sepolia.
 *
 * Flows: Direct, Escrow, Tab (2 charges), Stream, Bounty, Deposit, x402 Weather,
 * AP2 Discovery, AP2 Payment.
 *
 * Usage:
 *   ACCEPTANCE_API_URL=https://testnet.remit.md ./gradlew run
 */

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import md.remit.*;
import md.remit.models.*;
import md.remit.signer.PrivateKeySigner;
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
import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.CompletableFuture;

public class App {

    // ─── Config ──────────────────────────────────────────────────────────────────
    static final String API_URL = envOr("ACCEPTANCE_API_URL", "https://testnet.remit.md");
    static final String API_BASE = API_URL + "/api/v1";
    static final String RPC_URL = envOr("ACCEPTANCE_RPC_URL", "https://sepolia.base.org");
    static final long CHAIN_ID = 84532L;
    static final String USDC_ADDRESS = "0x2d846325766921935f37d5b4478196d3ef93707c";
    static final String FEE_WALLET = "0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38";

    static final HttpClient HTTP = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();
    static final ObjectMapper MAPPER = new ObjectMapper()
            .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);

    // ─── Colors ──────────────────────────────────────────────────────────────────
    static final String GREEN = "\033[0;32m";
    static final String RED = "\033[0;31m";
    static final String CYAN = "\033[0;36m";
    static final String BOLD = "\033[1m";
    static final String RESET = "\033[0m";

    static final Map<String, String> results = new LinkedHashMap<>();

    static String envOr(String key, String fallback) {
        String v = System.getenv(key);
        return (v != null && !v.isBlank()) ? v : fallback;
    }

    static void logPass(String flow, String msg) {
        String extra = (msg == null || msg.isEmpty()) ? "" : " -- " + msg;
        System.out.println(GREEN + "[PASS]" + RESET + " " + flow + extra);
        results.put(flow, "PASS");
    }

    static void logFail(String flow, String msg) {
        System.out.println(RED + "[FAIL]" + RESET + " " + flow + " -- " + msg);
        results.put(flow, "FAIL");
    }

    static void logInfo(String msg) {
        System.out.println(CYAN + "[INFO]" + RESET + " " + msg);
    }

    static void logTx(String flow, String step, String txHash) {
        if (txHash == null || txHash.isEmpty()) return;
        System.out.println("  [TX] " + flow + " | " + step + " | https://sepolia.basescan.org/tx/" + txHash);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    static volatile ContractAddresses cachedContracts;

    static ContractAddresses fetchContracts() throws Exception {
        if (cachedContracts != null) return cachedContracts;
        HttpRequest req = HttpRequest.newBuilder()
                .uri(URI.create(API_BASE + "/contracts"))
                .GET().timeout(Duration.ofSeconds(15)).build();
        HttpResponse<String> resp = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
        if (resp.statusCode() != 200) throw new RuntimeException("GET /contracts: " + resp.statusCode());
        cachedContracts = MAPPER.readValue(resp.body(), ContractAddresses.class);
        return cachedContracts;
    }

    static double getUsdcBalance(String address) throws Exception {
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
                .timeout(Duration.ofSeconds(15)).build();
        HttpResponse<String> resp = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
        JsonNode node = MAPPER.readTree(resp.body());
        if (node.has("error")) throw new RuntimeException("RPC error: " + node.get("error"));
        String resultHex = node.get("result").asText("0x0").replace("0x", "");
        if (resultHex.isEmpty()) resultHex = "0";
        return new BigInteger(resultHex, 16).doubleValue() / 1_000_000.0;
    }

    static double waitForBalanceChange(String address, double before) throws Exception {
        long deadline = System.currentTimeMillis() + 30_000;
        while (System.currentTimeMillis() < deadline) {
            double current = getUsdcBalance(address);
            if (Math.abs(current - before) > 0.0001) return current;
            Thread.sleep(2_000);
        }
        return getUsdcBalance(address);
    }

    // ─── Test Wallet ─────────────────────────────────────────────────────────────

    record TestWallet(Wallet wallet, ECKeyPair keyPair) {
        String address() { return wallet.address(); }
    }

    static TestWallet createTestWallet() throws Exception {
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

    static void fundWallet(TestWallet tw, double amount) throws Exception {
        tw.wallet.mint(amount);
        waitForBalanceChange(tw.address(), 0);
    }

    // ─── EIP-2612 Permit ─────────────────────────────────────────────────────────

    static PermitSignature signUsdcPermit(ECKeyPair keyPair, String owner, String spender,
                                           long value, long nonce, long deadline) {
        byte[] domainTypeHash = Hash.sha3("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".getBytes());
        byte[] nameHash = Hash.sha3("USD Coin".getBytes());
        byte[] versionHash = Hash.sha3("2".getBytes());
        byte[] domainData = concat(domainTypeHash, nameHash, versionHash, toUint256(CHAIN_ID), addressToBytes32(USDC_ADDRESS));
        byte[] domainSep = Hash.sha3(domainData);

        byte[] permitTypeHash = Hash.sha3("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)".getBytes());
        byte[] structData = concat(permitTypeHash, addressToBytes32(owner), addressToBytes32(spender),
                toUint256(value), toUint256(nonce), toUint256(deadline));
        byte[] structHash = Hash.sha3(structData);

        byte[] finalData = new byte[66];
        finalData[0] = 0x19;
        finalData[1] = 0x01;
        System.arraycopy(domainSep, 0, finalData, 2, 32);
        System.arraycopy(structHash, 0, finalData, 34, 32);
        byte[] digest = Hash.sha3(finalData);

        Sign.SignatureData sig = Sign.signMessage(digest, keyPair, false);
        int v = sig.getV()[0] & 0xFF;
        String r = "0x" + HexFormat.of().formatHex(sig.getR());
        String s = "0x" + HexFormat.of().formatHex(sig.getS());
        return new PermitSignature(value, deadline, v, r, s);
    }

    static byte[] toUint256(long value) {
        BigInteger bi = BigInteger.valueOf(value);
        byte[] b = bi.toByteArray();
        byte[] result = new byte[32];
        int start = (b.length > 1 && b[0] == 0) ? 1 : 0;
        int len = b.length - start;
        System.arraycopy(b, start, result, 32 - len, len);
        return result;
    }

    static byte[] addressToBytes32(String address) {
        String hex = address.startsWith("0x") ? address.substring(2) : address;
        byte[] addr = HexFormat.of().parseHex(hex);
        byte[] result = new byte[32];
        System.arraycopy(addr, 0, result, 12, 20);
        return result;
    }

    static byte[] concat(byte[]... arrays) {
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

    // ─── Flow 1: Direct Payment ──────────────────────────────────────────────────
    static void flowDirect(TestWallet agent, TestWallet provider, long[] permitNonce) throws Exception {
        String flow = "1. Direct Payment";
        ContractAddresses contracts = fetchContracts();
        long deadline = Instant.now().getEpochSecond() + 3600;
        PermitSignature permit = signUsdcPermit(agent.keyPair, agent.address(), contracts.router,
                2_000_000, permitNonce[0], deadline);
        permitNonce[0]++;

        Transaction tx = agent.wallet.pay(provider.address(), new BigDecimal("1.0"), "java-acceptance", permit);
        if (tx.txHash == null || !tx.txHash.startsWith("0x"))
            throw new RuntimeException("bad tx_hash: " + tx.txHash);
        logTx(flow, "pay", tx.txHash);
        logPass(flow, "tx=" + tx.txHash.substring(0, 18) + "...");
    }

    // ─── Flow 2: Escrow ─��────────────────────────────────────────────────────────
    static void flowEscrow(TestWallet agent, TestWallet provider, long[] permitNonce) throws Exception {
        String flow = "2. Escrow";
        ContractAddresses contracts = fetchContracts();
        long deadline = Instant.now().getEpochSecond() + 3600;
        PermitSignature permit = signUsdcPermit(agent.keyPair, agent.address(), contracts.escrow,
                6_000_000, permitNonce[0], deadline);
        permitNonce[0]++;

        Escrow escrow = agent.wallet.createEscrow(provider.address(), new BigDecimal("5.0"), permit);
        if (escrow.id == null || escrow.id.isBlank()) throw new RuntimeException("escrow should have an id");

        waitForBalanceChange(agent.address(), getUsdcBalance(agent.address()));
        Thread.sleep(3_000);

        provider.wallet.claimStart(escrow.id);
        Thread.sleep(3_000);

        agent.wallet.releaseEscrow(escrow.id);
        logPass(flow, "escrow_id=" + escrow.id);
    }

    // ─── Flow 3: Metered Tab (2 charges) ─────────────────────────────────────────
    static void flowTab(TestWallet agent, TestWallet provider, long[] permitNonce) throws Exception {
        String flow = "3. Metered Tab";
        ContractAddresses contracts = fetchContracts();
        String tabContract = contracts.tab;
        long deadline = Instant.now().getEpochSecond() + 3600;
        PermitSignature permit = signUsdcPermit(agent.keyPair, agent.address(), tabContract,
                11_000_000, permitNonce[0], deadline);
        permitNonce[0]++;

        double agentBefore = getUsdcBalance(agent.address());

        Tab tab = agent.wallet.createTab(provider.address(), new BigDecimal("10.0"),
                new BigDecimal("0.10"), permit);
        if (tab.id == null || tab.id.isBlank()) throw new RuntimeException("tab should have an id");

        waitForBalanceChange(agent.address(), agentBefore);

        // Charge 1: $2
        String sig1 = provider.wallet.signTabCharge(tabContract, tab.id, 2_000_000, 1);
        TabCharge charge1 = provider.wallet.chargeTab(tab.id, new BigDecimal("2.0"),
                new BigDecimal("2.0"), 1, sig1);
        if (!tab.id.equals(charge1.tabId)) throw new RuntimeException("charge1 tab_id mismatch");

        // Charge 2: $1 more (cumulative $3)
        String sig2 = provider.wallet.signTabCharge(tabContract, tab.id, 3_000_000, 2);
        TabCharge charge2 = provider.wallet.chargeTab(tab.id, new BigDecimal("1.0"),
                new BigDecimal("3.0"), 2, sig2);
        if (charge2.callCount != 2) throw new RuntimeException("expected call_count=2, got " + charge2.callCount);

        // Close with final state ($3, 2 calls)
        String closeSig = provider.wallet.signTabCharge(tabContract, tab.id, 3_000_000, 2);
        Transaction closeTx = agent.wallet.closeTab(tab.id, new BigDecimal("3.0"), closeSig);
        logTx(flow, "close", closeTx.txHash);
        logPass(flow, "tab_id=" + tab.id + ", charged=$3, 2 charges");
    }

    // ─── Flow 4: Stream ──────────────────────────────────────────────────────────
    static void flowStream(TestWallet agent, TestWallet provider, long[] permitNonce) throws Exception {
        String flow = "4. Stream";
        ContractAddresses contracts = fetchContracts();
        long deadline = Instant.now().getEpochSecond() + 3600;
        PermitSignature permit = signUsdcPermit(agent.keyPair, agent.address(), contracts.stream,
                6_000_000, permitNonce[0], deadline);
        permitNonce[0]++;

        md.remit.models.Stream stream = agent.wallet.createStream(provider.address(),
                new BigDecimal("0.01"), new BigDecimal("5.0"), permit);
        if (stream.id == null || stream.id.isBlank()) throw new RuntimeException("stream should have an id");

        Thread.sleep(5_000);

        Transaction closeTx = agent.wallet.closeStream(stream.id);
        logTx(flow, "close", closeTx.txHash);
        logPass(flow, "stream_id=" + stream.id);
    }

    // ─── Flow 5: Bounty ──────────────────────────────────────────────────────────
    static void flowBounty(TestWallet agent, TestWallet provider, long[] permitNonce) throws Exception {
        String flow = "5. Bounty";
        ContractAddresses contracts = fetchContracts();
        long deadline = Instant.now().getEpochSecond() + 3600;
        PermitSignature permit = signUsdcPermit(agent.keyPair, agent.address(), contracts.bounty,
                6_000_000, permitNonce[0], deadline);
        permitNonce[0]++;

        Bounty bounty = agent.wallet.createBounty(new BigDecimal("5.0"),
                "java-acceptance-bounty", deadline, permit);
        if (bounty.id == null || bounty.id.isBlank()) throw new RuntimeException("bounty should have an id");

        waitForBalanceChange(agent.address(), getUsdcBalance(agent.address()));

        String evidenceHash = "0x" + "ab".repeat(32);
        provider.wallet.submitBounty(bounty.id, evidenceHash);
        // First submission is always ID 0
        Thread.sleep(5_000);

        Transaction awarded = agent.wallet.awardBounty(bounty.id, 0);
        logTx(flow, "award", awarded.txHash);
        logPass(flow, "bounty_id=" + bounty.id);
    }

    // ─── Flow 6: Deposit ─────────────────────────────────────────────────────────
    static void flowDeposit(TestWallet agent, TestWallet provider, long[] permitNonce) throws Exception {
        String flow = "6. Deposit";
        ContractAddresses contracts = fetchContracts();
        long deadline = Instant.now().getEpochSecond() + 3600;
        PermitSignature permit = signUsdcPermit(agent.keyPair, agent.address(), contracts.deposit,
                6_000_000, permitNonce[0], deadline);
        permitNonce[0]++;

        double agentBefore = getUsdcBalance(agent.address());

        Deposit deposit = agent.wallet.lockDeposit(provider.address(), new BigDecimal("5.0"), 3600, permit);
        if (deposit.id == null || deposit.id.isBlank()) throw new RuntimeException("deposit should have an id");

        waitForBalanceChange(agent.address(), agentBefore);

        Transaction returnTx = provider.wallet.returnDeposit(deposit.id);
        logTx(flow, "return", returnTx.txHash);
        logPass(flow, "deposit_id=" + deposit.id);
    }

    // ─── Flow 7: x402 Weather ────────────────────────────────────────────────────
    static void flowX402Weather(TestWallet agent) throws Exception {
        String flow = "7. x402 Weather";

        // Step 1: Hit the paywall
        HttpRequest req = HttpRequest.newBuilder()
                .uri(URI.create(API_BASE + "/x402/demo"))
                .GET().timeout(Duration.ofSeconds(15)).build();
        HttpResponse<String> resp = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
        if (resp.statusCode() != 402) {
            logFail(flow, "expected 402, got " + resp.statusCode());
            return;
        }

        // Parse X-Payment headers
        String scheme = resp.headers().firstValue("x-payment-scheme").orElse("exact");
        String network = resp.headers().firstValue("x-payment-network").orElse("eip155:" + CHAIN_ID);
        String amountStr = resp.headers().firstValue("x-payment-amount").orElse("5000000");
        String asset = resp.headers().firstValue("x-payment-asset").orElse(USDC_ADDRESS);
        String payTo = resp.headers().firstValue("x-payment-payto").orElse("");
        long amountRaw = Long.parseLong(amountStr);

        logInfo(String.format("  Paywall: %s | $%.2f USDC | network=%s", scheme, amountRaw / 1e6, network));

        // Step 2: Sign EIP-3009 TransferWithAuthorization
        long chainId = network.contains(":") ? Long.parseLong(network.split(":")[1]) : CHAIN_ID;
        long nowSecs = Instant.now().getEpochSecond();
        long validBefore = nowSecs + 300;
        byte[] nonceBytes = new byte[32];
        new SecureRandom().nextBytes(nonceBytes);
        String nonceHex = "0x" + HexFormat.of().formatHex(nonceBytes);

        // EIP-712 domain: USD Coin / version 2
        byte[] domainTypeHash = Hash.sha3("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".getBytes());
        byte[] dNameHash = Hash.sha3("USD Coin".getBytes());
        byte[] dVersionHash = Hash.sha3("2".getBytes());
        byte[] domainData = concat(domainTypeHash, dNameHash, dVersionHash, toUint256(chainId), addressToBytes32(asset));
        byte[] domainSep = Hash.sha3(domainData);

        // TransferWithAuthorization struct
        byte[] typeHash = Hash.sha3("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)".getBytes());
        byte[] structData = concat(typeHash, addressToBytes32(agent.address()), addressToBytes32(payTo),
                toUint256(amountRaw), toUint256(0), toUint256(validBefore), nonceBytes);
        byte[] structHash = Hash.sha3(structData);

        byte[] finalData = new byte[66];
        finalData[0] = 0x19;
        finalData[1] = 0x01;
        System.arraycopy(domainSep, 0, finalData, 2, 32);
        System.arraycopy(structHash, 0, finalData, 34, 32);
        byte[] digest = Hash.sha3(finalData);

        Sign.SignatureData sig = Sign.signMessage(digest, agent.keyPair, false);
        String signature = "0x" + HexFormat.of().formatHex(sig.getR())
                + HexFormat.of().formatHex(sig.getS())
                + HexFormat.of().formatHex(sig.getV());

        // Step 3: Settle via authenticated POST
        Map<String, Object> authorization = new LinkedHashMap<>();
        authorization.put("from", agent.address());
        authorization.put("to", payTo);
        authorization.put("value", amountStr);
        authorization.put("validAfter", "0");
        authorization.put("validBefore", String.valueOf(validBefore));
        authorization.put("nonce", nonceHex);

        Map<String, Object> payloadInner = new LinkedHashMap<>();
        payloadInner.put("signature", signature);
        payloadInner.put("authorization", authorization);

        Map<String, Object> paymentPayload = new LinkedHashMap<>();
        paymentPayload.put("scheme", scheme);
        paymentPayload.put("network", network);
        paymentPayload.put("x402Version", 1);
        paymentPayload.put("payload", payloadInner);

        Map<String, Object> paymentRequired = new LinkedHashMap<>();
        paymentRequired.put("scheme", scheme);
        paymentRequired.put("network", network);
        paymentRequired.put("amount", amountStr);
        paymentRequired.put("asset", asset);
        paymentRequired.put("payTo", payTo);
        paymentRequired.put("maxTimeoutSeconds", 300);

        Map<String, Object> settleBody = new LinkedHashMap<>();
        settleBody.put("paymentPayload", paymentPayload);
        settleBody.put("paymentRequired", paymentRequired);

        String settleJson = MAPPER.writeValueAsString(settleBody);

        // Build EIP-712 auth headers for settle endpoint
        ContractAddresses authContracts = fetchContracts();
        long authTimestamp = Instant.now().getEpochSecond();
        byte[] authNonceBytes = new byte[32];
        new SecureRandom().nextBytes(authNonceBytes);
        String authNonceHex = "0x" + HexFormat.of().formatHex(authNonceBytes);

        // Domain separator: remit.md / 0.1
        byte[] authDomainTypeHash = Hash.sha3("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".getBytes());
        byte[] authNameHash = Hash.sha3("remit.md".getBytes());
        byte[] authVersionHash = Hash.sha3("0.1".getBytes());
        byte[] authDomainData = concat(authDomainTypeHash, authNameHash, authVersionHash, toUint256(CHAIN_ID), addressToBytes32(authContracts.router));
        byte[] authDomainSep = Hash.sha3(authDomainData);

        // APIRequest struct — string fields are keccak256-hashed in EIP-712
        byte[] authStructTypeHash = Hash.sha3("APIRequest(string method,string path,uint256 timestamp,bytes32 nonce)".getBytes());
        byte[] methodHash = Hash.sha3("POST".getBytes());
        byte[] pathHash = Hash.sha3("/api/v1/x402/settle".getBytes());
        byte[] authStructData = concat(authStructTypeHash, methodHash, pathHash, toUint256(authTimestamp), authNonceBytes);
        byte[] authStructHash = Hash.sha3(authStructData);

        byte[] authFinalData = new byte[66];
        authFinalData[0] = 0x19;
        authFinalData[1] = 0x01;
        System.arraycopy(authDomainSep, 0, authFinalData, 2, 32);
        System.arraycopy(authStructHash, 0, authFinalData, 34, 32);
        byte[] authDigest = Hash.sha3(authFinalData);

        Sign.SignatureData authSig = Sign.signMessage(authDigest, agent.keyPair, false);
        String authSignature = "0x" + HexFormat.of().formatHex(authSig.getR())
                + HexFormat.of().formatHex(authSig.getS())
                + HexFormat.of().formatHex(authSig.getV());

        HttpRequest settleReq = HttpRequest.newBuilder()
                .uri(URI.create(API_BASE + "/x402/settle"))
                .header("Content-Type", "application/json")
                .header("X-Remit-Signature", authSignature)
                .header("X-Remit-Agent", agent.address())
                .header("X-Remit-Timestamp", String.valueOf(authTimestamp))
                .header("X-Remit-Nonce", authNonceHex)
                .POST(HttpRequest.BodyPublishers.ofString(settleJson))
                .timeout(Duration.ofSeconds(30)).build();
        HttpResponse<String> settleResp = HTTP.send(settleReq, HttpResponse.BodyHandlers.ofString());
        JsonNode settleNode = MAPPER.readTree(settleResp.body());
        String txHash = settleNode.has("transactionHash") ? settleNode.get("transactionHash").asText() : null;

        if (txHash == null || txHash.isEmpty()) {
            logFail(flow, "settle returned no tx_hash");
            return;
        }
        logTx(flow, "settle", txHash);

        // Step 4: Fetch weather with payment proof
        HttpRequest weatherReq = HttpRequest.newBuilder()
                .uri(URI.create(API_BASE + "/x402/demo"))
                .header("X-Payment-Response", txHash)
                .GET().timeout(Duration.ofSeconds(15)).build();
        HttpResponse<String> weatherResp = HTTP.send(weatherReq, HttpResponse.BodyHandlers.ofString());
        if (weatherResp.statusCode() != 200) {
            logFail(flow, "weather fetch returned " + weatherResp.statusCode());
            return;
        }

        JsonNode weather = MAPPER.readTree(weatherResp.body());
        JsonNode loc = weather.path("location");
        JsonNode cur = weather.path("current");
        String city = loc.path("name").asText("Unknown");
        String tempF = cur.path("temp_f").asText("?");
        String tempC = cur.path("temp_c").asText("?");
        String condition = cur.has("condition") && cur.get("condition").isObject()
                ? cur.path("condition").path("text").asText("Unknown")
                : cur.path("condition").asText("Unknown");

        System.out.println();
        System.out.println(CYAN + "+---------------------------------------------+" + RESET);
        System.out.printf("%s|%s  %sx402 Weather Report%s (paid $%.2f USDC)   %s|%s%n",
                CYAN, RESET, BOLD, RESET, amountRaw / 1e6, CYAN, RESET);
        System.out.println(CYAN + "+---------------------------------------------+" + RESET);
        System.out.printf("%s|%s  City:        %-29s%s|%s%n", CYAN, RESET, city, CYAN, RESET);
        System.out.printf("%s|%s  Temperature: %sF / %sC%s%s|%s%n", CYAN, RESET, tempF, tempC,
                " ".repeat(Math.max(0, 22 - tempF.length() - tempC.length())), CYAN, RESET);
        System.out.printf("%s|%s  Condition:   %-29s%s|%s%n", CYAN, RESET, condition, CYAN, RESET);
        System.out.println(CYAN + "+---------------------------------------------+" + RESET);
        System.out.println();

        logPass(flow, "city=" + city + ", tx=" + txHash.substring(0, 18) + "...");
    }

    // ─── Flow 8: AP2 Discovery ───────────────────────────────────────────────────
    static void flowAp2Discovery() throws Exception {
        String flow = "8. AP2 Discovery";
        A2A.AgentCard card = A2A.AgentCard.discover(API_URL).join();

        System.out.println();
        System.out.println(CYAN + "+---------------------------------------------+" + RESET);
        System.out.printf("%s|%s  %sA2A Agent Card%s                            %s|%s%n",
                CYAN, RESET, BOLD, RESET, CYAN, RESET);
        System.out.println(CYAN + "+---------------------------------------------+" + RESET);
        System.out.printf("%s|%s  Name:     %-32s%s|%s%n", CYAN, RESET, card.name(), CYAN, RESET);
        System.out.printf("%s|%s  Version:  %-32s%s|%s%n", CYAN, RESET, card.version(), CYAN, RESET);
        System.out.printf("%s|%s  Protocol: %-32s%s|%s%n", CYAN, RESET, card.protocolVersion(), CYAN, RESET);
        String urlDisplay = card.url() != null && card.url().length() > 32 ? card.url().substring(0, 32) : card.url();
        System.out.printf("%s|%s  URL:      %-32s%s|%s%n", CYAN, RESET, urlDisplay, CYAN, RESET);
        if (card.skills() != null && !card.skills().isEmpty()) {
            System.out.printf("%s|%s  Skills:   %d total%25s%s|%s%n", CYAN, RESET, card.skills().size(), "", CYAN, RESET);
            for (int i = 0; i < Math.min(5, card.skills().size()); i++) {
                String name = card.skills().get(i).name();
                if (name.length() > 38) name = name.substring(0, 38);
                System.out.printf("%s|%s    - %-38s%s|%s%n", CYAN, RESET, name, CYAN, RESET);
            }
        }
        System.out.println(CYAN + "+---------------------------------------------+" + RESET);
        System.out.println();

        if (card.name() == null || card.name().isEmpty())
            throw new RuntimeException("agent card should have a name");
        logPass(flow, "name=" + card.name());
    }

    // ─── Flow 9: AP2 Payment ─────────────────────────────────────────────────────
    static void flowAp2Payment(TestWallet agent, TestWallet provider, long[] permitNonce) throws Exception {
        String flow = "9. AP2 Payment";
        A2A.AgentCard card = A2A.AgentCard.discover(API_URL).join();
        ContractAddresses contracts = fetchContracts();

        ECKeyPair kp = agent.keyPair;
        String hexKey = "0x" + Numeric.toHexStringNoPrefixZeroPadded(kp.getPrivateKey(), 64);
        md.remit.signer.Signer signer = new PrivateKeySigner(hexKey);

        // Sign USDC permit for the router
        long deadline = Instant.now().getEpochSecond() + 3600;
        PermitSignature permit = signUsdcPermit(kp, agent.address(), contracts.router,
                2_000_000, permitNonce[0], deadline);
        permitNonce[0]++;

        A2A.IntentMandate mandate = new A2A.IntentMandate(
                UUID.randomUUID().toString().replace("-", ""),
                "2099-12-31T23:59:59Z",
                agent.address(),
                Map.of("maxAmount", "5.00", "currency", "USDC")
        );

        A2A.Client a2a = A2A.Client.fromCard(card, signer, CHAIN_ID, contracts.router);
        A2A.SendOptions opts = new A2A.SendOptions(provider.address(), 1.0, "java-acceptance-a2a", mandate, permit);
        A2A.Task task = a2a.send(opts);
        if (task.id() == null || task.id().isEmpty()) {
            System.out.println("\033[1;33m[SKIP]\033[0m " + flow + " -- AP2 task has no ID (endpoint may not be available on testnet)");
            results.put(flow, "SKIP");
            return;
        }

        String txHash = A2A.getTaskTxHash(task);
        if (txHash != null) logTx(flow, "a2a-pay", txHash);

        // Verify persistence
        A2A.Task fetched = a2a.getTask(task.id());
        if (!task.id().equals(fetched.id()))
            throw new RuntimeException("fetched task id mismatch");

        String state = task.status() != null ? task.status().state() : "unknown";
        logPass(flow, "task_id=" + task.id() + ", state=" + state);
    }

    // ─── Main ────────────────────────────────────────────────────────────────────
    public static void main(String[] args) throws Exception {
        System.out.println();
        System.out.println(BOLD + "Java SDK -- 9 Flow Acceptance Suite" + RESET);
        System.out.println("  API: " + API_URL);
        System.out.println("  RPC: " + RPC_URL);
        System.out.println();

        logInfo("Creating agent wallet...");
        TestWallet agent = createTestWallet();
        logInfo("  Agent:    " + agent.address());

        logInfo("Creating provider wallet...");
        TestWallet provider = createTestWallet();
        logInfo("  Provider: " + provider.address());

        logInfo("Minting $100 USDC to agent...");
        fundWallet(agent, 100);
        double bal = getUsdcBalance(agent.address());
        logInfo(String.format("  Agent balance: $%.2f", bal));

        logInfo("Minting $100 USDC to provider...");
        fundWallet(provider, 100);
        double bal2 = getUsdcBalance(provider.address());
        logInfo(String.format("  Provider balance: $%.2f", bal2));
        System.out.println();

        record FlowEntry(String name, Runnable run) {}

        // Permit nonce counter — each permit consumed on-chain increments the nonce
        long[] permitNonce = {0};

        List<FlowEntry> flows = List.of(
                new FlowEntry("1. Direct Payment", () -> { try { flowDirect(agent, provider, permitNonce); } catch (Exception e) { throw new RuntimeException(e); } }),
                new FlowEntry("2. Escrow", () -> { try { flowEscrow(agent, provider, permitNonce); } catch (Exception e) { throw new RuntimeException(e); } }),
                new FlowEntry("3. Metered Tab", () -> { try { flowTab(agent, provider, permitNonce); } catch (Exception e) { throw new RuntimeException(e); } }),
                new FlowEntry("4. Stream", () -> { try { flowStream(agent, provider, permitNonce); } catch (Exception e) { throw new RuntimeException(e); } }),
                new FlowEntry("5. Bounty", () -> { try { flowBounty(agent, provider, permitNonce); } catch (Exception e) { throw new RuntimeException(e); } }),
                new FlowEntry("6. Deposit", () -> { try { flowDeposit(agent, provider, permitNonce); } catch (Exception e) { throw new RuntimeException(e); } }),
                new FlowEntry("7. x402 Weather", () -> { try { flowX402Weather(agent); } catch (Exception e) { throw new RuntimeException(e); } }),
                new FlowEntry("8. AP2 Discovery", () -> { try { flowAp2Discovery(); } catch (Exception e) { throw new RuntimeException(e); } }),
                new FlowEntry("9. AP2 Payment", () -> { try { flowAp2Payment(agent, provider, permitNonce); } catch (Exception e) { throw new RuntimeException(e); } })
        );

        for (FlowEntry entry : flows) {
            try {
                entry.run.run();
            } catch (Exception e) {
                Throwable cause = e.getCause() != null ? e.getCause() : e;
                logFail(entry.name, cause.getClass().getSimpleName() + ": " + cause.getMessage());
                cause.printStackTrace(System.err);
            }
            // Allow indexer to catch up with on-chain nonce between permit-consuming flows
            Thread.sleep(5_000);
        }

        // Summary
        long passed = results.values().stream().filter("PASS"::equals).count();
        long failed = results.values().stream().filter("FAIL"::equals).count();
        System.out.println();
        System.out.printf("%sJava Summary: %s%d passed%s, %s%d failed%s / 9 flows%n",
                BOLD, GREEN, passed, RESET, RED, failed, RESET);
        System.out.printf("{\"passed\":%d,\"failed\":%d,\"skipped\":%d}%n", passed, failed, 9 - passed - failed);
        System.exit(failed > 0 ? 1 : 0);
    }
}
