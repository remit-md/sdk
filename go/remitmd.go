// Package remitmd provides a Go SDK for the remit.md universal AI payment protocol.
//
// remit.md enables AI agents to send and receive USDC payments on EVM L2 chains
// (Base, Arbitrum, Optimism) with support for escrow, streaming, tabs, bounties,
// and deposits.
//
// # Quick Start
//
//	wallet, err := remitmd.NewWallet(os.Getenv("REMITMD_KEY"),
//	    remitmd.WithChain("base"),
//	)
//	if err != nil {
//	    log.Fatal(err)
//	}
//
//	tx, err := wallet.Pay(ctx, "0xRecipient...", decimal.NewFromFloat(1.50),
//	    remitmd.WithMemo("service fee"),
//	)
//
// # Testing
//
// Use MockRemit for unit tests — zero network, zero latency, deterministic:
//
//	mock := remitmd.NewMockRemit()
//	wallet := mock.Wallet()
//
//	tx, err := wallet.Pay(ctx, "0xRecipient", decimal.NewFromFloat(1.50))
//	require.NoError(t, err)
//	assert.True(t, mock.WasPaid("0xRecipient", decimal.NewFromFloat(1.50)))
//
// # Error Handling
//
// All errors are typed *RemitError with a machine-readable Code, actionable Message,
// and link to relevant documentation:
//
//	tx, err := wallet.Pay(ctx, badAddr, amount)
//	var remitErr *RemitError
//	if errors.As(err, &remitErr) {
//	    fmt.Println(remitErr.Code)    // "INVALID_ADDRESS"
//	    fmt.Println(remitErr.DocURL)  // "https://remit.md/docs/errors#INVALID_ADDRESS"
//	}
package remitmd
