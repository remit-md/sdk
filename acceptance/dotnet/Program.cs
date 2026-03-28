// Remit SDK Acceptance -- C#/.NET: 9 flows against Base Sepolia.
//
// Flows: Direct, Escrow, Tab (2 charges), Stream, Bounty, Deposit, x402 Weather,
// AP2 Discovery, AP2 Payment.
//
// Usage:
//   ACCEPTANCE_API_URL=https://testnet.remit.md dotnet run

using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Nethereum.Signer;
using Nethereum.Util;
using RemitMd;

// ─── Config ─────────────────────────────────────────────────────────────────────
var API_URL = Environment.GetEnvironmentVariable("ACCEPTANCE_API_URL") ?? "https://testnet.remit.md";
var API_BASE = $"{API_URL}/api/v1";
var RPC_URL = Environment.GetEnvironmentVariable("ACCEPTANCE_RPC_URL") ?? "https://sepolia.base.org";
const long CHAIN_ID = 84532;
const string USDC_ADDRESS = "0x2d846325766921935f37d5b4478196d3ef93707c";
const string FEE_WALLET = "0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38";

// ─── Colors ─────────────────────────────────────────────────────────────────────
const string GREEN = "\x1b[0;32m";
const string RED = "\x1b[0;31m";
const string CYAN = "\x1b[0;36m";
const string BOLD = "\x1b[1m";
const string RESET = "\x1b[0m";

var results = new Dictionary<string, string>();
var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };

void LogPass(string flow, string msg = "")
{
    var extra = string.IsNullOrEmpty(msg) ? "" : $" -- {msg}";
    Console.WriteLine($"{GREEN}[PASS]{RESET} {flow}{extra}");
    results[flow] = "PASS";
}

void LogFail(string flow, string msg)
{
    Console.WriteLine($"{RED}[FAIL]{RESET} {flow} -- {msg}");
    results[flow] = "FAIL";
}

void LogInfo(string msg) => Console.WriteLine($"{CYAN}[INFO]{RESET} {msg}");

void LogTx(string flow, string step, string? txHash)
{
    if (string.IsNullOrEmpty(txHash)) return;
    Console.WriteLine($"  [TX] {flow} | {step} | https://sepolia.basescan.org/tx/{txHash}");
}

// ─── Helpers ────────────────────────────────────────────────────────────────────

Dictionary<string, JsonElement>? _contractsCache = null;

async Task<Dictionary<string, JsonElement>> FetchContracts()
{
    if (_contractsCache is not null) return _contractsCache;
    var resp = await http.GetStringAsync($"{API_BASE}/contracts");
    _contractsCache = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(resp)!;
    return _contractsCache;
}

async Task<double> GetUsdcBalance(string address)
{
    var hex = address.ToLowerInvariant().Replace("0x", "").PadLeft(64, '0');
    var callData = "0x70a08231" + hex;
    var body = $"{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{{\"to\":\"{USDC_ADDRESS}\",\"data\":\"{callData}\"}},\"latest\"]}}";
    var resp = await http.PostAsync(RPC_URL, new StringContent(body, Encoding.UTF8, "application/json"));
    var json = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
    var resultHex = json.RootElement.GetProperty("result").GetString()!.Replace("0x", "");
    if (string.IsNullOrEmpty(resultHex)) resultHex = "0";
    var raw = ulong.Parse(resultHex, System.Globalization.NumberStyles.HexNumber);
    return raw / 1_000_000.0;
}

async Task<double> WaitForBalanceChange(string address, double before, int timeoutSecs = 30)
{
    var deadline = DateTime.UtcNow.AddSeconds(timeoutSecs);
    while (DateTime.UtcNow < deadline)
    {
        var current = await GetUsdcBalance(address);
        if (Math.Abs(current - before) > 0.0001) return current;
        await Task.Delay(2000);
    }
    return await GetUsdcBalance(address);
}

(Wallet Wallet, PrivateKeySigner Signer) CreateTestWallet(string routerAddress)
{
    var key = EthECKey.GenerateKey();
    var hexKey = "0x" + BitConverter.ToString(key.GetPrivateKeyAsBytes()).Replace("-", "").ToLowerInvariant();
    var wallet = new Wallet(hexKey, chain: "base", testnet: true, baseUrl: API_URL, routerAddress: routerAddress);
    var signer = new PrivateKeySigner(hexKey);
    return (wallet, signer);
}

async Task FundWallet(Wallet wallet, decimal amount)
{
    await wallet.MintAsync(amount);
    await WaitForBalanceChange(wallet.Address, 0);
}

// ─── Keccak256 helper (Eip712 is internal in the SDK) ───────────────────────────

byte[] Keccak256(string text) => Keccak256Bytes(Encoding.UTF8.GetBytes(text));
byte[] Keccak256Bytes(byte[] data) => new Sha3Keccack().CalculateHash(data);

// ─── EIP-2612 Permit Signing ────────────────────────────────────────────────────

PermitSignature SignUsdcPermit(PrivateKeySigner signer, string owner, string spender,
                                long value, long nonce, long deadline)
{
    var domainTypeHash = Keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    var nameHash = Keccak256("USD Coin");
    var versionHash = Keccak256("2");
    var domainData = ConcatBytes(domainTypeHash, nameHash, versionHash, PadUint256(CHAIN_ID), PadAddress(USDC_ADDRESS));
    var domainSep = Keccak256Bytes(domainData);

    var permitTypeHash = Keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    var structData = ConcatBytes(permitTypeHash, PadAddress(owner), PadAddress(spender),
                                 PadUint256(value), PadUint256(nonce), PadUint256(deadline));
    var structHash = Keccak256Bytes(structData);

    var finalData = new byte[66];
    finalData[0] = 0x19;
    finalData[1] = 0x01;
    Buffer.BlockCopy(domainSep, 0, finalData, 2, 32);
    Buffer.BlockCopy(structHash, 0, finalData, 34, 32);
    var digest = Keccak256Bytes(finalData);

    var sigHex = signer.Sign(digest);
    var sigBytes = Convert.FromHexString(sigHex.Replace("0x", ""));
    var r = "0x" + Convert.ToHexString(sigBytes[..32]).ToLowerInvariant();
    var s = "0x" + Convert.ToHexString(sigBytes[32..64]).ToLowerInvariant();
    var v = (int)sigBytes[64];

    return new PermitSignature(value, deadline, v, r, s);
}

byte[] PadUint256(long value)
{
    var result = new byte[32];
    var bytes = BitConverter.GetBytes((ulong)value);
    if (BitConverter.IsLittleEndian) Array.Reverse(bytes);
    Buffer.BlockCopy(bytes, 0, result, 24, 8);
    return result;
}

byte[] PadAddress(string address)
{
    var hex = address.Replace("0x", "");
    var bytes = Convert.FromHexString(hex);
    var result = new byte[32];
    Buffer.BlockCopy(bytes, 0, result, 12, 20);
    return result;
}

byte[] ConcatBytes(params byte[][] arrays)
{
    var total = arrays.Sum(a => a.Length);
    var result = new byte[total];
    var pos = 0;
    foreach (var a in arrays) { Buffer.BlockCopy(a, 0, result, pos, a.Length); pos += a.Length; }
    return result;
}

// ─── Flow 1: Direct Payment ────────────────────────────────────────────────────
async Task FlowDirect(Wallet agent, PrivateKeySigner agentSigner, Wallet provider)
{
    var flow = "1. Direct Payment";
    var contracts = await FetchContracts();
    var routerAddr = contracts["router"].GetString()!;
    var deadline = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600;
    var permit = SignUsdcPermit(agentSigner, agent.Address, routerAddr, 2_000_000, 0, deadline);

    var tx = await agent.PayAsync(provider.Address, 1.0m, memo: "dotnet-acceptance", permit: permit);
    if (string.IsNullOrEmpty(tx.TxHash) || !tx.TxHash.StartsWith("0x"))
        throw new Exception($"bad tx_hash: {tx.TxHash}");
    LogTx(flow, "pay", tx.TxHash);
    LogPass(flow, $"tx={tx.TxHash[..18]}...");
}

// ─── Flow 2: Escrow ────────────────────────────────────────────────────────────
async Task FlowEscrow(Wallet agent, PrivateKeySigner agentSigner, Wallet provider)
{
    var flow = "2. Escrow";
    var contracts = await FetchContracts();
    var escrowAddr = contracts["escrow"].GetString()!;
    var deadline = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600;
    var permit = SignUsdcPermit(agentSigner, agent.Address, escrowAddr, 6_000_000, 0, deadline);

    var escrow = await agent.CreateEscrowAsync(provider.Address, 5.0m, permit: permit);
    if (string.IsNullOrEmpty(escrow.Id)) throw new Exception("escrow should have an id");

    await WaitForBalanceChange(agent.Address, await GetUsdcBalance(agent.Address));
    await Task.Delay(3000);

    await provider.ClaimStartAsync(escrow.Id);
    await Task.Delay(3000);

    var released = await agent.ReleaseEscrowAsync(escrow.Id);
    LogTx(flow, "release", released.TxHash);
    LogPass(flow, $"escrow_id={escrow.Id}");
}

// ─── Flow 3: Metered Tab (2 charges) ───────────────────────────────────────────
async Task FlowTab(Wallet agent, PrivateKeySigner agentSigner, Wallet provider)
{
    var flow = "3. Metered Tab";
    var contracts = await FetchContracts();
    var tabAddr = contracts["tab"].GetString()!;
    var deadline = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600;
    var permit = SignUsdcPermit(agentSigner, agent.Address, tabAddr, 11_000_000, 0, deadline);

    var agentBefore = await GetUsdcBalance(agent.Address);

    var tab = await agent.CreateTabAsync(provider.Address, 10.0m, 0.10m, expiresSecs: 3600, permit: permit);
    if (string.IsNullOrEmpty(tab.Id)) throw new Exception("tab should have an id");

    await WaitForBalanceChange(agent.Address, agentBefore);

    // Charge 1: $2
    var sig1 = provider.SignTabCharge(tabAddr, tab.Id, 2_000_000, 1);
    var charge1 = await provider.ChargeTabAsync(tab.Id, 2.0m, 2.0m, 1, sig1);
    if (charge1.TabId != tab.Id) throw new Exception("charge1 tab_id mismatch");

    // Charge 2: $1 more (cumulative $3)
    var sig2 = provider.SignTabCharge(tabAddr, tab.Id, 3_000_000, 2);
    var charge2 = await provider.ChargeTabAsync(tab.Id, 1.0m, 3.0m, 2, sig2);
    if (charge2.CallCount != 2) throw new Exception($"expected call_count=2, got {charge2.CallCount}");

    // Close with final state ($3, 2 calls)
    var closeSig = provider.SignTabCharge(tabAddr, tab.Id, 3_000_000, 2);
    var closed = await agent.CloseTabAsync(tab.Id, 3.0m, closeSig);

    LogPass(flow, $"tab_id={tab.Id}, charged=$3, 2 charges");
}

// ─── Flow 4: Stream ────────────────────────────────────────────────────────────
async Task FlowStream(Wallet agent, PrivateKeySigner agentSigner, Wallet provider)
{
    var flow = "4. Stream";
    var contracts = await FetchContracts();
    var streamAddr = contracts["stream"].GetString()!;
    var deadline = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600;
    var permit = SignUsdcPermit(agentSigner, agent.Address, streamAddr, 6_000_000, 0, deadline);

    var stream = await agent.CreateStreamAsync(provider.Address, 0.01m, 5.0m, permit: permit);
    if (string.IsNullOrEmpty(stream.Id)) throw new Exception("stream should have an id");

    await Task.Delay(5000);

    var closeTx = await agent.CloseStreamAsync(stream.Id);
    LogTx(flow, "close", closeTx.TxHash);
    LogPass(flow, $"stream_id={stream.Id}");
}

// ─── Flow 5: Bounty ────────────────────────────────────────────────────────────
async Task FlowBounty(Wallet agent, PrivateKeySigner agentSigner, Wallet provider)
{
    var flow = "5. Bounty";
    var contracts = await FetchContracts();
    var bountyAddr = contracts["bounty"].GetString()!;
    var deadline = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600;
    var permit = SignUsdcPermit(agentSigner, agent.Address, bountyAddr, 6_000_000, 0, deadline);

    var bounty = await agent.CreateBountyAsync(5.0m, "dotnet-acceptance-bounty", deadlineSecs: 3600, permit: permit);
    if (string.IsNullOrEmpty(bounty.Id)) throw new Exception("bounty should have an id");

    await WaitForBalanceChange(agent.Address, await GetUsdcBalance(agent.Address));

    var evidenceHash = "0x" + string.Concat(Enumerable.Repeat("ab", 32));
    var submission = await provider.SubmitBountyAsync(bounty.Id, evidenceHash);
    if (submission.Id <= 0) throw new Exception("submission should have an id");
    await Task.Delay(5000);

    var awarded = await agent.AwardBountyAsync(bounty.Id, submission.Id);
    LogPass(flow, $"bounty_id={bounty.Id}");
}

// ─── Flow 6: Deposit ───────────────────────────────────────────────────────────
async Task FlowDeposit(Wallet agent, PrivateKeySigner agentSigner, Wallet provider)
{
    var flow = "6. Deposit";
    var contracts = await FetchContracts();
    var depositAddr = contracts["deposit"].GetString()!;
    var deadline = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600;
    var permit = SignUsdcPermit(agentSigner, agent.Address, depositAddr, 6_000_000, 0, deadline);

    var agentBefore = await GetUsdcBalance(agent.Address);

    var deposit = await agent.LockDepositAsync(provider.Address, 5.0m, expireSecs: 3600, permit: permit);
    if (string.IsNullOrEmpty(deposit.Id)) throw new Exception("deposit should have an id");

    await WaitForBalanceChange(agent.Address, agentBefore);

    var returnTx = await provider.ReturnDepositAsync(deposit.Id);
    LogTx(flow, "return", returnTx.TxHash);
    LogPass(flow, $"deposit_id={deposit.Id}");
}

// ─── Flow 7: x402 Weather ──────────────────────────────────────────────────────
async Task FlowX402Weather(Wallet agent, PrivateKeySigner agentSigner)
{
    var flow = "7. x402 Weather";

    // Step 1: Hit the paywall
    var resp = await http.GetAsync($"{API_BASE}/x402/demo");
    if (resp.StatusCode != HttpStatusCode.PaymentRequired)
    {
        LogFail(flow, $"expected 402, got {(int)resp.StatusCode}");
        return;
    }

    // Parse X-Payment headers
    var scheme = resp.Headers.TryGetValues("x-payment-scheme", out var sv) ? sv.FirstOrDefault() ?? "exact" : "exact";
    var network = resp.Headers.TryGetValues("x-payment-network", out var nv) ? nv.FirstOrDefault() ?? $"eip155:{CHAIN_ID}" : $"eip155:{CHAIN_ID}";
    var amountStr = resp.Headers.TryGetValues("x-payment-amount", out var av) ? av.FirstOrDefault() ?? "5000000" : "5000000";
    var asset = resp.Headers.TryGetValues("x-payment-asset", out var asv) ? asv.FirstOrDefault() ?? USDC_ADDRESS : USDC_ADDRESS;
    var payTo = resp.Headers.TryGetValues("x-payment-payto", out var pv) ? pv.FirstOrDefault() ?? "" : "";
    var amountRaw = long.Parse(amountStr);

    LogInfo($"  Paywall: {scheme} | ${amountRaw / 1e6:F2} USDC | network={network}");

    // Step 2: Sign EIP-3009 TransferWithAuthorization
    var chainId = network.Contains(':') ? long.Parse(network.Split(':')[1]) : CHAIN_ID;
    var nowSecs = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
    var validBefore = nowSecs + 300;
    var nonceBytes = RandomNumberGenerator.GetBytes(32);
    var nonceHex = "0x" + Convert.ToHexString(nonceBytes).ToLowerInvariant();

    // EIP-712 domain: USD Coin / version 2
    var domainTypeHash = Keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    var dNameHash = Keccak256("USD Coin");
    var dVersionHash = Keccak256("2");
    var domainData = ConcatBytes(domainTypeHash, dNameHash, dVersionHash, PadUint256(chainId), PadAddress(asset));
    var domainSep = Keccak256Bytes(domainData);

    // TransferWithAuthorization struct
    var typeHash = Keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");
    var structData = ConcatBytes(typeHash, PadAddress(agent.Address), PadAddress(payTo),
                                  PadUint256(amountRaw), PadUint256(0), PadUint256(validBefore), nonceBytes);
    var structHash = Keccak256Bytes(structData);

    var payload = new byte[66];
    payload[0] = 0x19;
    payload[1] = 0x01;
    Buffer.BlockCopy(domainSep, 0, payload, 2, 32);
    Buffer.BlockCopy(structHash, 0, payload, 34, 32);
    var digest = Keccak256Bytes(payload);

    var signature = agentSigner.Sign(digest);

    // Step 3: Settle via authenticated POST
    var settleBody = new
    {
        paymentPayload = new
        {
            scheme,
            network,
            x402Version = 1,
            payload = new
            {
                signature,
                authorization = new
                {
                    from = agent.Address,
                    to = payTo,
                    value = amountStr,
                    validAfter = "0",
                    validBefore = validBefore.ToString(),
                    nonce = nonceHex,
                },
            },
        },
        paymentRequired = new
        {
            scheme,
            network,
            amount = amountStr,
            asset,
            payTo,
            maxTimeoutSeconds = 300,
        },
    };

    var settleJson = JsonSerializer.Serialize(settleBody);
    var settleResp = await http.PostAsync($"{API_BASE}/x402/settle",
        new StringContent(settleJson, Encoding.UTF8, "application/json"));
    var settleResult = JsonDocument.Parse(await settleResp.Content.ReadAsStringAsync());
    var txHash = settleResult.RootElement.TryGetProperty("transactionHash", out var txProp) ? txProp.GetString() : null;

    if (string.IsNullOrEmpty(txHash))
    {
        LogFail(flow, $"settle returned no tx_hash");
        return;
    }
    LogTx(flow, "settle", txHash);

    // Step 4: Fetch weather with payment proof
    var weatherReq = new HttpRequestMessage(HttpMethod.Get, $"{API_BASE}/x402/demo");
    weatherReq.Headers.Add("X-Payment-Response", txHash);
    var weatherResp = await http.SendAsync(weatherReq);
    if (weatherResp.StatusCode != HttpStatusCode.OK)
    {
        LogFail(flow, $"weather fetch returned {(int)weatherResp.StatusCode}");
        return;
    }

    var weather = JsonDocument.Parse(await weatherResp.Content.ReadAsStringAsync()).RootElement;
    var loc = weather.TryGetProperty("location", out var l) ? l : default;
    var cur = weather.TryGetProperty("current", out var c) ? c : default;

    var city = loc.ValueKind == JsonValueKind.Object && loc.TryGetProperty("name", out var cn) ? cn.GetString() ?? "Unknown" : "Unknown";
    var tempF = cur.ValueKind == JsonValueKind.Object && cur.TryGetProperty("temp_f", out var tf) ? tf.ToString() : "?";
    var tempC = cur.ValueKind == JsonValueKind.Object && cur.TryGetProperty("temp_c", out var tc) ? tc.ToString() : "?";
    var condition = cur.ValueKind == JsonValueKind.Object && cur.TryGetProperty("condition", out var cond)
        ? (cond.ValueKind == JsonValueKind.Object && cond.TryGetProperty("text", out var ct) ? ct.GetString() ?? "Unknown" : cond.ToString())
        : "Unknown";

    Console.WriteLine();
    Console.WriteLine($"{CYAN}+---------------------------------------------+{RESET}");
    Console.WriteLine($"{CYAN}|{RESET}  {BOLD}x402 Weather Report{RESET} (paid ${amountRaw / 1e6:F2} USDC)   {CYAN}|{RESET}");
    Console.WriteLine($"{CYAN}+---------------------------------------------+{RESET}");
    Console.WriteLine($"{CYAN}|{RESET}  City:        {city,-29}{CYAN}|{RESET}");
    Console.WriteLine($"{CYAN}|{RESET}  Temperature: {tempF}F / {tempC}C{new string(' ', Math.Max(0, 22 - tempF.Length - tempC.Length))}{CYAN}|{RESET}");
    Console.WriteLine($"{CYAN}|{RESET}  Condition:   {condition,-29}{CYAN}|{RESET}");
    Console.WriteLine($"{CYAN}+---------------------------------------------+{RESET}");
    Console.WriteLine();

    LogPass(flow, $"city={city}, tx={txHash![..18]}...");
}

// ─── Flow 8: AP2 Discovery ─────────────────────────────────────────────────────
async Task FlowAp2Discovery()
{
    var flow = "8. AP2 Discovery";
    var card = await AgentCard.DiscoverAsync(API_URL);

    Console.WriteLine();
    Console.WriteLine($"{CYAN}+---------------------------------------------+{RESET}");
    Console.WriteLine($"{CYAN}|{RESET}  {BOLD}A2A Agent Card{RESET}                            {CYAN}|{RESET}");
    Console.WriteLine($"{CYAN}+---------------------------------------------+{RESET}");
    Console.WriteLine($"{CYAN}|{RESET}  Name:     {card.Name,-32}{CYAN}|{RESET}");
    Console.WriteLine($"{CYAN}|{RESET}  Version:  {card.Version,-32}{CYAN}|{RESET}");
    Console.WriteLine($"{CYAN}|{RESET}  Protocol: {card.ProtocolVersion,-32}{CYAN}|{RESET}");
    Console.WriteLine($"{CYAN}|{RESET}  URL:      {(card.Url.Length > 32 ? card.Url[..32] : card.Url),-32}{CYAN}|{RESET}");
    if (card.Skills is { Count: > 0 })
    {
        Console.WriteLine($"{CYAN}|{RESET}  Skills:   {card.Skills.Count} total{new string(' ', 25)}{CYAN}|{RESET}");
        foreach (var s in card.Skills.Take(5))
        {
            var name = s.Name.Length > 38 ? s.Name[..38] : s.Name;
            Console.WriteLine($"{CYAN}|{RESET}    - {name,-38}{CYAN}|{RESET}");
        }
    }
    Console.WriteLine($"{CYAN}+---------------------------------------------+{RESET}");
    Console.WriteLine();

    if (string.IsNullOrEmpty(card.Name)) throw new Exception("agent card should have a name");
    LogPass(flow, $"name={card.Name}");
}

// ─── Flow 9: AP2 Payment ───────────────────────────────────────────────────────
async Task FlowAp2Payment(Wallet agent, PrivateKeySigner agentSigner, Wallet provider)
{
    var flow = "9. AP2 Payment";
    var card = await AgentCard.DiscoverAsync(API_URL);

    var contracts = await FetchContracts();
    var routerAddr = contracts["router"].GetString()!;

    var mandate = new IntentMandate(
        MandateId: Guid.NewGuid().ToString("N"),
        ExpiresAt: "2099-12-31T23:59:59Z",
        Issuer: agent.Address,
        Allowance: new IntentMandateAllowance(MaxAmount: "5.00", Currency: "USDC")
    );

    using var a2a = A2AClient.FromCard(card, agentSigner, chain: "base-sepolia", verifyingContract: routerAddr);
    var task = await a2a.SendAsync(provider.Address, 1.0m, memo: "dotnet-acceptance-a2a", mandate: mandate);
    if (string.IsNullOrEmpty(task.Id)) throw new Exception("a2a task should have an id");

    var txHash = task.GetTxHash();
    if (!string.IsNullOrEmpty(txHash))
        LogTx(flow, "a2a-pay", txHash);

    // Verify persistence
    var fetched = await a2a.GetTaskAsync(task.Id);
    if (fetched.Id != task.Id) throw new Exception("fetched task id mismatch");

    LogPass(flow, $"task_id={task.Id}, state={task.Status.State}");
}

// ─── Main ───────────────────────────────────────────────────────────────────────
Console.WriteLine();
Console.WriteLine($"{BOLD}C#/.NET SDK -- 9 Flow Acceptance Suite{RESET}");
Console.WriteLine($"  API: {API_URL}");
Console.WriteLine($"  RPC: {RPC_URL}");
Console.WriteLine();

var contracts = await FetchContracts();
var routerAddress = contracts["router"].GetString()!;

LogInfo("Creating agent wallet...");
var (agentWallet, agentSigner) = CreateTestWallet(routerAddress);
LogInfo($"  Agent:    {agentWallet.Address}");

LogInfo("Creating provider wallet...");
var (providerWallet, _providerSigner) = CreateTestWallet(routerAddress);
LogInfo($"  Provider: {providerWallet.Address}");

LogInfo("Minting $100 USDC to agent...");
await FundWallet(agentWallet, 100);
var bal = await GetUsdcBalance(agentWallet.Address);
LogInfo($"  Agent balance: ${bal:F2}");

LogInfo("Minting $100 USDC to provider...");
await FundWallet(providerWallet, 100);
var bal2 = await GetUsdcBalance(providerWallet.Address);
LogInfo($"  Provider balance: ${bal2:F2}");
Console.WriteLine();

var flows = new (string Name, Func<Task> Run)[]
{
    ("1. Direct Payment", () => FlowDirect(agentWallet, agentSigner, providerWallet)),
    ("2. Escrow", () => FlowEscrow(agentWallet, agentSigner, providerWallet)),
    ("3. Metered Tab", () => FlowTab(agentWallet, agentSigner, providerWallet)),
    ("4. Stream", () => FlowStream(agentWallet, agentSigner, providerWallet)),
    ("5. Bounty", () => FlowBounty(agentWallet, agentSigner, providerWallet)),
    ("6. Deposit", () => FlowDeposit(agentWallet, agentSigner, providerWallet)),
    ("7. x402 Weather", () => FlowX402Weather(agentWallet, agentSigner)),
    ("8. AP2 Discovery", FlowAp2Discovery),
    ("9. AP2 Payment", () => FlowAp2Payment(agentWallet, agentSigner, providerWallet)),
};

foreach (var (name, run) in flows)
{
    try
    {
        await run();
    }
    catch (Exception ex)
    {
        LogFail(name, $"{ex.GetType().Name}: {ex.Message}");
        Console.Error.WriteLine(ex.ToString());
    }
}

// Summary
var passed = results.Values.Count(v => v == "PASS");
var failed = results.Values.Count(v => v == "FAIL");
Console.WriteLine();
Console.WriteLine($"{BOLD}C# Summary: {GREEN}{passed} passed{RESET}, {RED}{failed} failed{RESET} / 9 flows");
Console.WriteLine(JsonSerializer.Serialize(new { passed, failed, skipped = 9 - passed - failed }));
Environment.Exit(failed > 0 ? 1 : 0);
