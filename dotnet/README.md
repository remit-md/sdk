# remit.md — C#/.NET SDK

[![CI](https://github.com/remit-md/sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/remit-md/sdk/actions/workflows/ci.yml)

Pay any AI agent in USDC with three lines of code.

```csharp
var wallet = Wallet.FromEnvironment();
var tx = await wallet.PayAsync("0xRecipient...", 1.50m, "for your API response");
Console.WriteLine($"Paid! TX: {tx.TxHash}");
```

## Installation

```bash
dotnet add package RemitMd
```

## Setup

```bash
export REMITMD_KEY=0xYourPrivateKey
export REMITMD_CHAIN=base          # optional, default: base
export REMITMD_TESTNET=true        # optional, default: false (mainnet)
```

Or pass a key directly:

```csharp
var wallet = new Wallet("0xYourPrivateKey");
```

## Payment Primitives

Permits are **automatic** — the SDK signs an EIP-2612 USDC permit before every
payment, so you never need to deal with `approve()` transactions.

### Direct Payment

```csharp
var tx = await wallet.PayAsync("0xAgent...", 1.00m, "for data analysis");
```

### Escrow (pay-on-delivery)

```csharp
var escrow = await wallet.CreateEscrowAsync("0xAgent...", 25m, "code review");
// verify the work...
var tx = await wallet.ReleaseEscrowAsync(escrow.Id);
```

### Tab (micro-payment channel)

```csharp
var contracts = await wallet.GetContractsAsync();
var tab = await wallet.CreateTabAsync("0xAPIProvider...", 5m, 0.001m);

// Provider charges with EIP-712 signature
var sig = wallet.SignTabCharge(contracts.Tab, tab.Id, 1000000L, 1);
await wallet.ChargeTabAsync(tab.Id, 0.001m, 0.001m, 1, sig);

// Close when done — unused funds return
await wallet.CloseTabAsync(tab.Id);
```

### Stream (pay-per-second)

```csharp
// Pay $1/hour = 0.000277 USDC/second
var stream = await wallet.CreateStreamAsync("0xAgent...", 0.000277m, 10m);
```

### Bounty (open reward)

```csharp
var bounty = await wallet.CreateBountyAsync(100m, "Summarize Q3 earnings reports");
await wallet.AwardBountyAsync(bounty.Id, "0xWinner...");
```

## Balance & Reputation

```csharp
var balance = await wallet.BalanceAsync();
Console.WriteLine($"Balance: {balance.Usdc:F2} USDC");

var rep = await wallet.ReputationAsync("0xAgent...");
Console.WriteLine($"Score: {rep.Score}/1000");
```

## Testing with MockRemit

`MockRemit` is an in-memory mock that requires zero network and has sub-millisecond latency.

```csharp
var mock = new MockRemit(startingBalance: 100m);
var wallet = mock.Wallet(); // no private key needed

var tx = await wallet.PayAsync("0xAgent...", 5.00m);

// Assertions
Assert.True(mock.WasPaid("0xAgent...", 5.00m));
Assert.Equal(5.00m, mock.TotalPaidTo("0xAgent..."));
Assert.Equal(95m, mock.Balance);
Assert.Single(mock.Transactions);

mock.Reset(); // clear between test cases
```

### Testing insufficient funds

```csharp
mock.SetBalance(0.50m);
var ex = await Assert.ThrowsAsync<RemitError>(() => wallet.PayAsync("0xAgent...", 1.00m));
Assert.Equal(ErrorCodes.InsufficientFunds, ex.Code);
```

## Semantic Kernel Integration

```csharp
using RemitMd.SemanticKernel;

var builder = Kernel.CreateBuilder();
builder.AddOpenAIChatCompletion("gpt-4o", Environment.GetEnvironmentVariable("OPENAI_KEY")!);

var wallet = Wallet.FromEnvironment();
builder.Plugins.AddFromObject(new RemitMdPlugin(wallet), "remitmd");

var kernel = builder.Build();
// Agent can now call: remitmd-pay, remitmd-balance, remitmd-reputation,
// remitmd-create_escrow, remitmd-release_escrow, remitmd-open_tab,
// remitmd-debit_tab, remitmd-post_bounty, remitmd-spending_summary,
// remitmd-remaining_budget
```

## Error Handling

```csharp
try
{
    await wallet.PayAsync("0xAgent...", 1000m);
}
catch (RemitError ex) when (ex.Code == ErrorCodes.InsufficientFunds)
{
    Console.WriteLine($"Not enough USDC: {ex.Message}");
}
catch (RemitError ex)
{
    Console.WriteLine($"Payment failed [{ex.Code}]: {ex.Message}");
    if (ex.Context is not null)
        foreach (var (k, v) in ex.Context) Console.WriteLine($"  {k}: {v}");
}
```

All errors include:
- `Code` — machine-readable constant from `ErrorCodes`
- `Message` — human-readable description with actual numbers (e.g. "have $5.00, need $100.00")
- `Context` — structured data (e.g. `required`, `available`, `required_units`, `available_units`)
- `HttpStatus` — HTTP status code (null for client-side validation errors)

## Additional Methods

```csharp
// Contract discovery (cached per session)
var contracts = await wallet.GetContractsAsync();

// Webhooks
var wh = await wallet.RegisterWebhookAsync("https://...", new[] { "payment.received" });

// Operator links (optional: messages, agentName)
var fundLink = await wallet.CreateFundLinkAsync();
var withdrawLink = await wallet.CreateWithdrawLinkAsync(messages: new[] { "Withdraw" }, agentName: "my-agent");

// Testnet funding
var result = await wallet.MintAsync(100m);  // $100 testnet USDC
```

## Supported Chains

| Chain         | Environment          |
|---------------|----------------------|
| `base`        | Mainnet              |
| `base`        | Sepolia (testnet)    |

```csharp
// Testnet
var wallet = new Wallet(key, chain: "base", testnet: true);

// Local / self-hosted
var wallet = new Wallet(key, baseUrl: "http://localhost:3000/v0");
```

## Advanced: Manual Permits

Permits are signed automatically by every payment method. If you need manual
control (custom deadline, pre-signed permits, batching), use `SignPermitAsync`
or `SignUsdcPermit` directly:

```csharp
// Auto-fetches nonce, defaults deadline to 1 hour
var permit = await wallet.SignPermitAsync(spender: "0xRouterAddr...", amount: 5.00m);

// Pass explicit permit to skip auto-signing
var tx = await wallet.PayAsync("0xAgent...", 5.00m, permit: permit);
```

For full control over every parameter:

```csharp
var permit = wallet.SignUsdcPermit(
    spender: "0xRouterAddr...",
    value: 5_000_000,          // raw USDC base units (6 decimals)
    nonce: 0,                  // fetch with FetchUsdcNonceAsync or track manually
    deadline: DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 600
);
```

You can also override the JSON-RPC URL used for nonce fetching:

```csharp
var wallet = new Wallet(key, chain: "base", testnet: true, rpcUrl: "https://my-rpc.example.com");
// or via environment variable: REMITMD_RPC_URL
```

## License

MIT — see [LICENSE](../../LICENSE)
