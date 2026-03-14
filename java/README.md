# remit.md Java/Kotlin SDK

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
// 3-line integration
Wallet wallet = RemitMd.fromEnv();  // reads REMITMD_KEY env var
wallet.pay("0xRecipient...", new BigDecimal("1.50"));
```

### Kotlin
```kotlin
val wallet = RemitMd.fromEnv()
wallet.pay("0xRecipient...", 1.50.usdc)
```

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
Tab tab = wallet.createTab("0xApiService...", new BigDecimal("5.00"));

// Charge per API call (off-chain, cheap)
wallet.debitTab(tab.id, new BigDecimal("0.003"), "inference call");
wallet.debitTab(tab.id, new BigDecimal("0.003"), "inference call");

// Settle all charges on-chain when done
wallet.settleTab(tab.id);
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

Error codes are defined in `ErrorCodes`:
- `INVALID_ADDRESS`, `INVALID_AMOUNT`, `INVALID_CHAIN`, `INVALID_PARAM`
- `INSUFFICIENT_FUNDS`
- `ESCROW_NOT_FOUND`, `ESCROW_WRONG_STATE`
- `TAB_NOT_FOUND`, `TAB_LIMIT_EXCEEDED`
- `BOUNTY_NOT_FOUND`, `DEPOSIT_NOT_FOUND`
- `UNAUTHORIZED`, `FORBIDDEN`, `RATE_LIMITED`
- `SERVER_ERROR`, `CHAIN_ERROR`

---

## License

MIT — see [LICENSE](../../LICENSE)
