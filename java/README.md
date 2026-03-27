# remit.md Java/Kotlin SDK

> [Skill MD](https://remit.md) · [Docs](https://remit.md/docs) · [Agent Spec](https://remit.md/agent.md)

[![CI](https://github.com/remit-md/sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/remit-md/sdk/actions/workflows/ci.yml)

Java and Kotlin SDK for [remit.md](https://remit.md) — the universal USDC payment protocol for AI agents.

## Installation

### Gradle (Kotlin DSL)
```kotlin
dependencies {
    implementation("md.remit:remitmd-sdk:0.1.0")
}
```

### Gradle (Groovy)
```groovy
dependencies {
    implementation 'md.remit:remitmd-sdk:0.1.0'
}
```

### Maven
```xml
<dependency>
    <groupId>md.remit</groupId>
    <artifactId>remitmd-sdk</artifactId>
    <version>0.1.0</version>
</dependency>
```

Requires **Java 11+**.

---

## Quick Start

### Java
```java
// 2-line integration — permits are handled automatically
Wallet wallet = RemitMd.fromEnv();  // reads REMITMD_KEY env var
wallet.pay("0xRecipient...", new BigDecimal("1.50"));
```

### Kotlin
```kotlin
val wallet = RemitMd.fromEnv()
wallet.pay("0xRecipient...", 1.50.usdc)
```

## Local Signer (Recommended)

The local signer delegates key management to `remit signer`, a localhost HTTP server that holds your encrypted key. Your agent only needs a URL and token — no private key in the environment.

```bash
export REMIT_SIGNER_URL=http://127.0.0.1:7402
export REMIT_SIGNER_TOKEN=rmit_sk_...
```

```java
// Explicit
HttpSigner signer = new HttpSigner("http://127.0.0.1:7402", "rmit_sk_...");
Wallet wallet = RemitMd.withSigner(signer).build();

// Or auto-detect from env (recommended)
Wallet wallet = RemitMd.fromEnv(); // detects REMIT_SIGNER_URL automatically
```

`RemitMd.fromEnv()` detects signer credentials automatically. Priority: `REMIT_SIGNER_URL` > `REMITMD_KEY`.

---

## Configuration

```java
// From environment variables (recommended)
Wallet wallet = RemitMd.fromEnv();
// REMITMD_KEY   — hex-encoded private key (required)
// REMITMD_CHAIN — chain name: "base" (default: "base")
// REMITMD_TESTNET — "1" or "true" for testnet

// Explicit configuration
Wallet wallet = RemitMd.withKey("0x...")
    .chain("base")
    .testnet(true)
    .build();

// Custom signer (KMS, HSM, etc.)
Wallet wallet = RemitMd.withSigner(hash -> myKmsClient.sign(hash))
    .build();
```

---

## Payment Methods

All payment methods auto-sign EIP-2612 permits. No manual permit handling needed.

### Direct Payment
```java
Transaction tx = wallet.pay("0xRecipient...", new BigDecimal("1.50"), "API call fee");
```

### Escrow
```java
// Lock funds until work is verified
Escrow escrow = wallet.createEscrow("0xWorker...", new BigDecimal("10.00"), "data analysis task");

// Release after work is done
wallet.releaseEscrow(escrow.id);

// Cancel if work wasn't completed
wallet.cancelEscrow(escrow.id);
```

### Tabs (Micro-payment Channels)
```java
// Open a channel for high-frequency micro-payments
Tab tab = wallet.createTab("0xApiService...", new BigDecimal("5.00"), new BigDecimal("0.003"));

// Provider charges with EIP-712 signature
ContractAddresses contracts = wallet.getContracts();
String sig = wallet.signTabCharge(contracts.tab, tab.id, 3000000L, 1);
wallet.chargeTab(tab.id, new BigDecimal("0.003"), new BigDecimal("0.003"), 1, sig);

// Close when done — unused funds return
wallet.closeTab(tab.id, new BigDecimal("0.003"), sig);
```

### Bounties
```java
// Post a task for any agent to claim
Bounty bounty = wallet.createBounty(new BigDecimal("25.00"), "Summarize the Q4 report");

// Award to the best submission
wallet.awardBounty(bounty.id, "0xWinner...");
```

### Streams
```java
// Per-second payment stream (e.g., for uptime payments)
Stream stream = wallet.createStream("0xRecipient...",
    new BigDecimal("0.0001"),   // USDC per second
    new BigDecimal("100.00")); // initial deposit

wallet.withdrawStream(stream.id);
```

---

## Testing with MockRemit

MockRemit provides a zero-network, zero-latency in-memory mock — no private key or API access needed.

```java
// JUnit 5 example
class MyAgentTest {
    MockRemit mock = new MockRemit();
    Wallet wallet = mock.wallet();

    @Test
    void agentPaysForService() {
        String serviceAddr = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";

        // Your agent code under test
        myAgent.processRequest(wallet, serviceAddr, "analyze this data");

        // Assert payments
        assertTrue(mock.wasPaid(serviceAddr, new BigDecimal("0.01")));
        assertEquals(new BigDecimal("0.01"), mock.totalPaidTo(serviceAddr));
    }

    @BeforeEach
    void resetState() { mock.reset(); }
}
```

---

## Framework Integrations

### Spring AI
```kotlin
@Configuration
class RemitConfig {
    @Bean
    fun remitWallet() = RemitMd.fromEnv()

    @Bean
    fun remitTools(wallet: Wallet) = RemitMdTools(wallet)
}

@Bean
fun chatClient(builder: ChatClient.Builder, tools: RemitMdTools) =
    builder.defaultTools(tools).build()
```

Your agent can then use natural language:
> "Pay 5 USDC to 0xWorker for completing the analysis"

### LangChain4j
```kotlin
val tools = md.remit.langchain4j.RemitMdTools(wallet)

val agent = AiServices.builder(PaymentAgent::class.java)
    .chatLanguageModel(model)
    .tools(tools)
    .build()
```

---

## Kotlin DSL

```kotlin
import md.remit.usdc  // BigDecimal extension
import md.remit.escrow
import md.remit.tab
import md.remit.bounty

// Decimal extension
wallet.pay("0xRecipient...", 1.50.usdc)

// Escrow DSL
wallet.escrow("0xWorker...", 10.00.usdc) {
    memo = "data analysis"
    expiresIn = Duration.ofDays(7)
}

// Tab DSL
val tab = wallet.tab("0xApiService...", 50.00.usdc) {
    expiresIn = Duration.ofHours(24)
}

// Bounty DSL
wallet.bounty(25.00.usdc, "Write unit tests for this module") {
    expiresIn = Duration.ofDays(3)
}
```

---

## Error Handling

All methods throw `RemitError` with a machine-readable code and an actionable message:

```java
try {
    wallet.pay("0xinvalid", new BigDecimal("1.00"));
} catch (RemitError e) {
    System.out.println(e.getCode());    // "INVALID_ADDRESS"
    System.out.println(e.getMessage()); // "Invalid address "0xinvalid": expected 0x-prefixed..."
    System.out.println(e.getDetails()); // {"address": "0xinvalid"}
}
```

Enriched errors include actual numbers for balance-related failures:
```java
// e.getCode() == "INSUFFICIENT_BALANCE"
// e.getMessage() == "Insufficient USDC balance: have $5.00, need $100.00"
// e.getDetails() == {"required": "100.00", "available": "5.00", ...}
```

## Additional Methods

```java
// Contract discovery (cached per session)
ContractAddresses contracts = wallet.getContracts();

// Webhooks
wallet.registerWebhook("https://...", List.of("payment.received"));

// Operator links (overloaded: optional messages, agentName)
LinkResponse link = wallet.createFundLink();
LinkResponse link = wallet.createWithdrawLink(List.of("Withdraw"), "my-agent");

// Testnet funding
MintResponse result = wallet.mint(100.0);  // $100 testnet USDC
```

---

## Advanced: Manual Permits

All payment methods auto-sign permits. Use these methods only if you need explicit control over nonce, deadline, or USDC address.

### signPermit (recommended)

Auto-fetches the on-chain nonce and defaults deadline to 1 hour:

```java
ContractAddresses contracts = wallet.getContracts();
PermitSignature permit = wallet.signPermit(contracts.router, new BigDecimal("5.00"));
wallet.pay("0xRecipient...", new BigDecimal("5.00"), "task", permit);
```

### signUsdcPermit (low-level)

Full control over all permit parameters:

```java
PermitSignature permit = wallet.signUsdcPermit(
    contracts.router,     // spender
    5_000_000L,           // value in base units (6 decimals)
    1999999999L,          // deadline (unix timestamp)
    0L                    // nonce
);
```

---

## License

MIT — see [LICENSE](../../LICENSE)
