// remit.md MockRemit example — test payments without spending real USDC.
using RemitMd;

const string Agent = "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

// MockRemit: zero network, deterministic, ideal for unit tests.
var mock   = new MockRemit(startingBalance: 100m);
var wallet = mock.Wallet(); // no private key needed

// Direct payment
var tx = await wallet.PayAsync(Agent, 5.00m, "data analysis");
Console.WriteLine($"Pay:     {tx.Amount:F2} USDC → {tx.To[..8]}... (TX: {tx.TxHash[..10]}...)");

// Escrow lifecycle
var escrow = await wallet.CreateEscrowAsync(Agent, 25m, "code review");
Console.WriteLine($"Escrow:  {escrow.Id} | status={escrow.Status} | amount={escrow.Amount:F2}");

var releaseTx = await wallet.ReleaseEscrowAsync(escrow.Id);
Console.WriteLine($"Release: {releaseTx.Amount:F2} USDC released");

// Tab (micro-payment channel)
var tab = await wallet.CreateTabAsync(Agent, limitAmount: 10m, perUnit: 0.001m);
await wallet.ChargeTabAsync(tab.Id, 0.001m, 0.001m, 1, "0xsig1");
await wallet.ChargeTabAsync(tab.Id, 0.001m, 0.002m, 2, "0xsig2");
await wallet.ChargeTabAsync(tab.Id, 0.001m, 0.003m, 3, "0xsig3");
await wallet.CloseTabAsync(tab.Id, 0.003m, "0xsig_final");
Console.WriteLine($"Tab:     closed {tab.Id} (3 × $0.001)");

// Inspection
Console.WriteLine($"\nBalance: {mock.Balance:F2} USDC");
Console.WriteLine($"Paid to {Agent[..8]}...: {mock.TotalPaidTo(Agent):F4} USDC");
Console.WriteLine($"Transactions: {mock.Transactions.Count}");
Console.WriteLine($"WasPaid $5:   {mock.WasPaid(Agent, 5.00m)}");
