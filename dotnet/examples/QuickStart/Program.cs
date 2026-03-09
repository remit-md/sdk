// remit.md C# quickstart — pay any AI agent in 3 lines.
using RemitMd;

var wallet = Wallet.FromEnvironment(); // reads REMITMD_KEY, REMITMD_CHAIN, REMITMD_TESTNET
var tx = await wallet.PayAsync("0xRecipientAddress000000000000000000000000", 1.50m, "for your API response");
Console.WriteLine($"Paid! TX: {tx.TxHash}");
