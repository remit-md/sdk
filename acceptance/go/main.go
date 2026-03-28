// Go SDK Acceptance — 9 flows against Base Sepolia.
//
// Flows: Direct, Escrow, Tab (2 charges), Stream, Bounty, Deposit,
// x402 Weather, AP2 Discovery, AP2 Payment.
//
// Usage:
//
//	ACCEPTANCE_API_URL=https://testnet.remit.md go run .
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"math/big"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	remitmd "github.com/remit-md/sdk/go"
	"github.com/shopspring/decimal"
)

// ─── Config ───────────────────────────────────────────────────────────────────

var (
	apiURL      = envOr("ACCEPTANCE_API_URL", "https://testnet.remit.md")
	apiBase     = apiURL + "/api/v1"
	rpcURL      = envOr("ACCEPTANCE_RPC_URL", "https://sepolia.base.org")
	chainID     = big.NewInt(84532)
	usdcAddress = common.HexToAddress("0x2d846325766921935f37d5b4478196d3ef93707c")
	feeWallet = "0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38"
)

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// ─── Colors ───────────────────────────────────────────────────────────────────

const (
	green  = "\033[0;32m"
	red    = "\033[0;31m"
	cyan   = "\033[0;36m"
	yellow = "\033[1;33m"
	bold   = "\033[1m"
	reset  = "\033[0m"
)

// ─── Results ──────────────────────────────────────────────────────────────────

type result struct {
	name   string
	status string // "PASS", "FAIL"
}

var results []result

func logPass(flow, msg string) {
	extra := ""
	if msg != "" {
		extra = " — " + msg
	}
	fmt.Printf("%s[PASS]%s %s%s\n", green, reset, flow, extra)
	results = append(results, result{flow, "PASS"})
}

func logFail(flow, msg string) {
	fmt.Printf("%s[FAIL]%s %s — %s\n", red, reset, flow, msg)
	results = append(results, result{flow, "FAIL"})
}

func logInfo(msg string) {
	fmt.Printf("%s[INFO]%s %s\n", cyan, reset, msg)
}

func logTx(flow, step, txHash string) {
	fmt.Printf("  [TX] %s | %s | https://sepolia.basescan.org/tx/%s\n", flow, step, txHash)
}

// ─── Contract discovery ───────────────────────────────────────────────────────

type contracts struct {
	Router  string `json:"router"`
	Escrow  string `json:"escrow"`
	Tab     string `json:"tab"`
	Stream  string `json:"stream"`
	Bounty  string `json:"bounty"`
	Deposit string `json:"deposit"`
	USDC    string `json:"usdc"`
}

var cachedContracts *contracts

func fetchContracts() (*contracts, error) {
	if cachedContracts != nil {
		return cachedContracts, nil
	}
	resp, err := http.Get(apiBase + "/contracts")
	if err != nil {
		return nil, fmt.Errorf("GET /contracts: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("GET /contracts returned %d", resp.StatusCode)
	}
	var c contracts
	if err := json.NewDecoder(resp.Body).Decode(&c); err != nil {
		return nil, fmt.Errorf("decode /contracts: %w", err)
	}
	cachedContracts = &c
	return cachedContracts, nil
}

// ─── Wallet helpers ───────────────────────────────────────────────────────────

type testWallet struct {
	*remitmd.Wallet
	key *ecdsa.PrivateKey
}

func createWallet() (*testWallet, error) {
	c, err := fetchContracts()
	if err != nil {
		return nil, err
	}
	key, err := crypto.GenerateKey()
	if err != nil {
		return nil, fmt.Errorf("generate key: %w", err)
	}
	hexKey := "0x" + hex.EncodeToString(crypto.FromECDSA(key))
	wallet, err := remitmd.NewWallet(hexKey,
		remitmd.WithTestnet(),
		remitmd.WithBaseURL(apiURL),
		remitmd.WithRouterAddress(c.Router),
	)
	if err != nil {
		return nil, fmt.Errorf("NewWallet: %w", err)
	}
	return &testWallet{Wallet: wallet, key: key}, nil
}

func fundWallet(w *testWallet, amount float64) error {
	ctx := context.Background()
	_, err := w.Mint(ctx, amount)
	if err != nil {
		return fmt.Errorf("Mint: %w", err)
	}
	waitForBalanceChange(w.Address(), 0)
	return nil
}

// ─── On-chain balance via RPC ─────────────────────────────────────────────────

func getUsdcBalance(address string) float64 {
	padded := strings.ToLower(strings.TrimPrefix(address, "0x"))
	for len(padded) < 64 {
		padded = "0" + padded
	}
	callData := "0x70a08231" + padded

	reqBody := fmt.Sprintf(
		`{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"%s","data":"%s"},"latest"]}`,
		usdcAddress.Hex(), callData,
	)

	resp, err := http.Post(rpcURL, "application/json", strings.NewReader(reqBody))
	if err != nil {
		return 0
	}
	defer resp.Body.Close()

	var res struct {
		Result string `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&res); err != nil {
		return 0
	}

	bal, ok := new(big.Int).SetString(strings.TrimPrefix(res.Result, "0x"), 16)
	if !ok {
		return 0
	}

	f, _ := new(big.Float).Quo(
		new(big.Float).SetInt(bal),
		new(big.Float).SetFloat64(1e6),
	).Float64()
	return f
}

func waitForBalanceChange(address string, before float64) float64 {
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		current := getUsdcBalance(address)
		if math.Abs(current-before) > 0.0001 {
			return current
		}
		time.Sleep(2 * time.Second)
	}
	return getUsdcBalance(address)
}

// ─── EIP-2612 Permit Signing ──────────────────────────────────────────────────

func signUSDCPermit(
	key *ecdsa.PrivateKey,
	owner, spender common.Address,
	value, nonce, deadline *big.Int,
) (*remitmd.PermitSignature, error) {
	bytes32T, _ := abi.NewType("bytes32", "", nil)
	uint256T, _ := abi.NewType("uint256", "", nil)
	addressT, _ := abi.NewType("address", "", nil)

	domainTypeHash := crypto.Keccak256Hash(
		[]byte("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
	)
	nameHash := crypto.Keccak256Hash([]byte("USD Coin"))
	versionHash := crypto.Keccak256Hash([]byte("2"))

	domainPacked, err := abi.Arguments{
		{Type: bytes32T},
		{Type: bytes32T},
		{Type: bytes32T},
		{Type: uint256T},
		{Type: addressT},
	}.Pack(domainTypeHash, nameHash, versionHash, chainID, usdcAddress)
	if err != nil {
		return nil, fmt.Errorf("pack domain: %w", err)
	}
	domainSep := crypto.Keccak256Hash(domainPacked)

	permitTypeHash := crypto.Keccak256Hash(
		[]byte("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
	)
	structPacked, err := abi.Arguments{
		{Type: bytes32T},
		{Type: addressT},
		{Type: addressT},
		{Type: uint256T},
		{Type: uint256T},
		{Type: uint256T},
	}.Pack(permitTypeHash, owner, spender, value, nonce, deadline)
	if err != nil {
		return nil, fmt.Errorf("pack struct: %w", err)
	}
	structHash := crypto.Keccak256Hash(structPacked)

	digest := crypto.Keccak256Hash(
		append([]byte("\x19\x01"), append(domainSep[:], structHash[:]...)...),
	)

	sig, err := crypto.Sign(digest[:], key)
	if err != nil {
		return nil, fmt.Errorf("sign: %w", err)
	}
	sig[64] += 27

	return &remitmd.PermitSignature{
		Value:    value.Int64(),
		Deadline: deadline.Int64(),
		V:        int(sig[64]),
		R:        "0x" + hex.EncodeToString(sig[:32]),
		S:        "0x" + hex.EncodeToString(sig[32:64]),
	}, nil
}

// ─── EIP-712 TabCharge Signing ────────────────────────────────────────────────

func signTabCharge(
	key *ecdsa.PrivateKey,
	tabContract common.Address,
	tabID string,
	totalCharged *big.Int,
	callCount uint32,
) (string, error) {
	bytes32T, _ := abi.NewType("bytes32", "", nil)
	uint256T, _ := abi.NewType("uint256", "", nil)
	addressT, _ := abi.NewType("address", "", nil)

	domainTypeHash := crypto.Keccak256Hash(
		[]byte("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
	)
	nameHash := crypto.Keccak256Hash([]byte("RemitTab"))
	versionHash := crypto.Keccak256Hash([]byte("1"))

	domainPacked, err := abi.Arguments{
		{Type: bytes32T},
		{Type: bytes32T},
		{Type: bytes32T},
		{Type: uint256T},
		{Type: addressT},
	}.Pack(domainTypeHash, nameHash, versionHash, chainID, tabContract)
	if err != nil {
		return "", fmt.Errorf("pack tab domain: %w", err)
	}
	domainSep := crypto.Keccak256Hash(domainPacked)

	tabChargeTypeHash := crypto.Keccak256Hash(
		[]byte("TabCharge(bytes32 tabId,uint96 totalCharged,uint32 callCount)"),
	)

	var tabIDBytes [32]byte
	copy(tabIDBytes[:], []byte(tabID))

	structPacked, err := abi.Arguments{
		{Type: bytes32T},
		{Type: bytes32T},
		{Type: uint256T},
		{Type: uint256T},
	}.Pack(
		tabChargeTypeHash,
		tabIDBytes,
		totalCharged,
		new(big.Int).SetUint64(uint64(callCount)),
	)
	if err != nil {
		return "", fmt.Errorf("pack tab struct: %w", err)
	}
	structHash := crypto.Keccak256Hash(structPacked)

	digest := crypto.Keccak256Hash(
		append([]byte("\x19\x01"), append(domainSep[:], structHash[:]...)...),
	)

	sig, err := crypto.Sign(digest[:], key)
	if err != nil {
		return "", fmt.Errorf("sign tab charge: %w", err)
	}
	sig[64] += 27

	return "0x" + hex.EncodeToString(sig), nil
}

// ─── EIP-3009 TransferWithAuthorization Signing ───────────────────────────────

func signEIP3009(
	key *ecdsa.PrivateKey,
	from, to common.Address,
	value *big.Int,
	validAfter, validBefore *big.Int,
	nonce [32]byte,
) (string, error) {
	bytes32T, _ := abi.NewType("bytes32", "", nil)
	uint256T, _ := abi.NewType("uint256", "", nil)
	addressT, _ := abi.NewType("address", "", nil)

	// USDC domain separator
	domainTypeHash := crypto.Keccak256Hash(
		[]byte("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
	)
	nameHash := crypto.Keccak256Hash([]byte("USD Coin"))
	versionHash := crypto.Keccak256Hash([]byte("2"))

	domainPacked, err := abi.Arguments{
		{Type: bytes32T},
		{Type: bytes32T},
		{Type: bytes32T},
		{Type: uint256T},
		{Type: addressT},
	}.Pack(domainTypeHash, nameHash, versionHash, chainID, usdcAddress)
	if err != nil {
		return "", fmt.Errorf("pack domain: %w", err)
	}
	domainSep := crypto.Keccak256Hash(domainPacked)

	transferTypeHash := crypto.Keccak256Hash(
		[]byte("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"),
	)
	structPacked, err := abi.Arguments{
		{Type: bytes32T},
		{Type: addressT},
		{Type: addressT},
		{Type: uint256T},
		{Type: uint256T},
		{Type: uint256T},
		{Type: bytes32T},
	}.Pack(transferTypeHash, from, to, value, validAfter, validBefore, nonce)
	if err != nil {
		return "", fmt.Errorf("pack 3009 struct: %w", err)
	}
	structHash := crypto.Keccak256Hash(structPacked)

	digest := crypto.Keccak256Hash(
		append([]byte("\x19\x01"), append(domainSep[:], structHash[:]...)...),
	)

	sig, err := crypto.Sign(digest[:], key)
	if err != nil {
		return "", fmt.Errorf("sign eip3009: %w", err)
	}
	sig[64] += 27

	return "0x" + hex.EncodeToString(sig), nil
}

// ─── EIP-712 API Auth ────────────────────────────────────────────────────────

func signAPIAuth(key *ecdsa.PrivateKey, method, path string, routerAddress string) (sig, agentAddr, ts, nonceHex string, err error) {
	bytes32T, _ := abi.NewType("bytes32", "", nil)
	uint256T, _ := abi.NewType("uint256", "", nil)
	addressT, _ := abi.NewType("address", "", nil)

	// Domain: remit.md / 0.1
	domainTypeHash := crypto.Keccak256Hash(
		[]byte("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
	)
	nameHash := crypto.Keccak256Hash([]byte("remit.md"))
	versionHash := crypto.Keccak256Hash([]byte("0.1"))

	domainPacked, err := abi.Arguments{
		{Type: bytes32T},
		{Type: bytes32T},
		{Type: bytes32T},
		{Type: uint256T},
		{Type: addressT},
	}.Pack(domainTypeHash, nameHash, versionHash, chainID, common.HexToAddress(routerAddress))
	if err != nil {
		return "", "", "", "", fmt.Errorf("pack auth domain: %w", err)
	}
	domainSep := crypto.Keccak256Hash(domainPacked)

	// APIRequest struct — string fields are keccak256-hashed in EIP-712
	authTypeHash := crypto.Keccak256Hash(
		[]byte("APIRequest(string method,string path,uint256 timestamp,bytes32 nonce)"),
	)

	timestamp := big.NewInt(time.Now().Unix())
	var nonceBytes [32]byte
	rand.Read(nonceBytes[:])

	methodHash := crypto.Keccak256Hash([]byte(method))
	pathHash := crypto.Keccak256Hash([]byte(path))

	structPacked, err := abi.Arguments{
		{Type: bytes32T},
		{Type: bytes32T},
		{Type: bytes32T},
		{Type: uint256T},
		{Type: bytes32T},
	}.Pack(authTypeHash, methodHash, pathHash, timestamp, nonceBytes)
	if err != nil {
		return "", "", "", "", fmt.Errorf("pack auth struct: %w", err)
	}
	structHash := crypto.Keccak256Hash(structPacked)

	digest := crypto.Keccak256Hash(
		append([]byte("\x19\x01"), append(domainSep[:], structHash[:]...)...),
	)

	sigBytes, err := crypto.Sign(digest[:], key)
	if err != nil {
		return "", "", "", "", fmt.Errorf("sign auth: %w", err)
	}
	sigBytes[64] += 27

	addr := crypto.PubkeyToAddress(key.PublicKey).Hex()
	return "0x" + hex.EncodeToString(sigBytes),
		addr,
		fmt.Sprintf("%d", timestamp.Int64()),
		"0x" + hex.EncodeToString(nonceBytes[:]),
		nil
}

// ─── Flow 1: Direct Payment ──────────────────────────────────────────────────

func flowDirect(agent, provider *testWallet, permitNonce *int64) {
	flow := "1. Direct Payment"
	ctx := context.Background()

	c, err := fetchContracts()
	if err != nil {
		logFail(flow, err.Error())
		return
	}

	permit, err := signUSDCPermit(agent.key,
		crypto.PubkeyToAddress(agent.key.PublicKey),
		common.HexToAddress(c.Router),
		big.NewInt(2_000_000), // $2 USDC
		big.NewInt(*permitNonce),
		big.NewInt(time.Now().Unix()+3600),
	)
	*permitNonce++
	if err != nil {
		logFail(flow, err.Error())
		return
	}

	tx, err := agent.Pay(ctx, provider.Address(), decimal.NewFromFloat(1.0),
		remitmd.WithMemo("acceptance-direct"),
		remitmd.WithPayPermit(permit),
	)
	if err != nil {
		logFail(flow, fmt.Sprintf("Pay: %v", err))
		return
	}
	if !strings.HasPrefix(tx.TxHash, "0x") {
		logFail(flow, fmt.Sprintf("bad tx_hash: %s", tx.TxHash))
		return
	}
	logTx(flow, "pay", tx.TxHash)
	logPass(flow, fmt.Sprintf("tx=%s...", tx.TxHash[:18]))
}

// ─── Flow 2: Escrow ──────────────────────────────────────────────────────────

func flowEscrow(agent, provider *testWallet, permitNonce *int64) {
	flow := "2. Escrow"
	ctx := context.Background()

	c, err := fetchContracts()
	if err != nil {
		logFail(flow, err.Error())
		return
	}

	permit, err := signUSDCPermit(agent.key,
		crypto.PubkeyToAddress(agent.key.PublicKey),
		common.HexToAddress(c.Escrow),
		big.NewInt(6_000_000), // $6 USDC
		big.NewInt(*permitNonce),
		big.NewInt(time.Now().Unix()+3600),
	)
	*permitNonce++
	if err != nil {
		logFail(flow, err.Error())
		return
	}

	escrow, err := agent.CreateEscrow(ctx, provider.Address(), decimal.NewFromFloat(5.0),
		remitmd.WithEscrowMemo("acceptance-escrow"),
		remitmd.WithEscrowPermit(permit),
	)
	if err != nil {
		logFail(flow, fmt.Sprintf("CreateEscrow: %v", err))
		return
	}
	if escrow.InvoiceID == "" {
		logFail(flow, "escrow should have an InvoiceID")
		return
	}
	if escrow.TxHash != "" {
		logTx(flow, "fund", escrow.TxHash)
	}

	agentBefore := getUsdcBalance(agent.Address())
	waitForBalanceChange(agent.Address(), agentBefore)
	time.Sleep(3 * time.Second)

	claim, err := provider.ClaimStart(ctx, escrow.InvoiceID)
	if err != nil {
		logFail(flow, fmt.Sprintf("ClaimStart: %v", err))
		return
	}
	if claim != nil && claim.TxHash != "" {
		logTx(flow, "claimStart", claim.TxHash)
	}
	time.Sleep(3 * time.Second)

	release, err := agent.ReleaseEscrow(ctx, escrow.InvoiceID)
	if err != nil {
		logFail(flow, fmt.Sprintf("ReleaseEscrow: %v", err))
		return
	}
	if release != nil && release.TxHash != "" {
		logTx(flow, "release", release.TxHash)
	}
	logPass(flow, fmt.Sprintf("escrow_id=%s", escrow.InvoiceID))
}

// ─── Flow 3: Metered Tab (2 charges) ─────────────────────────────────────────

func flowTab(agent, provider *testWallet, permitNonce *int64) {
	flow := "3. Metered Tab"
	ctx := context.Background()

	c, err := fetchContracts()
	if err != nil {
		logFail(flow, err.Error())
		return
	}
	tabContract := common.HexToAddress(c.Tab)

	permit, err := signUSDCPermit(agent.key,
		crypto.PubkeyToAddress(agent.key.PublicKey),
		tabContract,
		big.NewInt(11_000_000), // $11 USDC
		big.NewInt(*permitNonce),
		big.NewInt(time.Now().Unix()+3600),
	)
	*permitNonce++
	if err != nil {
		logFail(flow, err.Error())
		return
	}

	payerBefore := getUsdcBalance(agent.Address())

	tab, err := agent.CreateTab(ctx, provider.Address(),
		decimal.NewFromFloat(10.0),
		decimal.NewFromFloat(0.10),
		remitmd.WithTabPermit(permit),
	)
	if err != nil {
		logFail(flow, fmt.Sprintf("CreateTab: %v", err))
		return
	}
	if tab.ID == "" {
		logFail(flow, "tab ID should not be empty")
		return
	}
	if tab.TxHash != "" {
		logTx(flow, "open", tab.TxHash)
	}

	waitForBalanceChange(agent.Address(), payerBefore)

	// Charge 1: $2
	sig1, err := signTabCharge(provider.key, tabContract, tab.ID, big.NewInt(2_000_000), 1)
	if err != nil {
		logFail(flow, fmt.Sprintf("signTabCharge1: %v", err))
		return
	}
	charge1, err := provider.ChargeTab(ctx, tab.ID, 2.0, 2.0, 1, sig1)
	if err != nil {
		logFail(flow, fmt.Sprintf("ChargeTab1: %v", err))
		return
	}
	logInfo(fmt.Sprintf("  Tab charge 1: amount=%s, cumulative=%s", charge1.Amount, charge1.Cumulative))

	// Charge 2: $1 more (cumulative $3)
	sig2, err := signTabCharge(provider.key, tabContract, tab.ID, big.NewInt(3_000_000), 2)
	if err != nil {
		logFail(flow, fmt.Sprintf("signTabCharge2: %v", err))
		return
	}
	charge2, err := provider.ChargeTab(ctx, tab.ID, 1.0, 3.0, 2, sig2)
	if err != nil {
		logFail(flow, fmt.Sprintf("ChargeTab2: %v", err))
		return
	}
	logInfo(fmt.Sprintf("  Tab charge 2: amount=%s, cumulative=%s", charge2.Amount, charge2.Cumulative))

	// Close with final state ($3, 2 calls)
	closeSig, err := signTabCharge(provider.key, tabContract, tab.ID, big.NewInt(3_000_000), 2)
	if err != nil {
		logFail(flow, fmt.Sprintf("signCloseTab: %v", err))
		return
	}
	closed, err := agent.CloseTab(ctx, tab.ID,
		remitmd.WithCloseTabAmount(3.0),
		remitmd.WithCloseTabSig(closeSig),
	)
	if err != nil {
		logFail(flow, fmt.Sprintf("CloseTab: %v", err))
		return
	}
	if closed.TxHash != "" {
		logTx(flow, "close", closed.TxHash)
	}
	logPass(flow, fmt.Sprintf("tab_id=%s, charged=$3, 2 charges", tab.ID))
}

// ─── Flow 4: Stream ──────────────────────────────────────────────────────────

func flowStream(agent, provider *testWallet, permitNonce *int64) {
	flow := "4. Stream"
	ctx := context.Background()

	c, err := fetchContracts()
	if err != nil {
		logFail(flow, err.Error())
		return
	}

	permit, err := signUSDCPermit(agent.key,
		crypto.PubkeyToAddress(agent.key.PublicKey),
		common.HexToAddress(c.Stream),
		big.NewInt(6_000_000), // $6 USDC
		big.NewInt(*permitNonce),
		big.NewInt(time.Now().Unix()+3600),
	)
	*permitNonce++
	if err != nil {
		logFail(flow, err.Error())
		return
	}

	payerBefore := getUsdcBalance(agent.Address())

	stream, err := agent.CreateStream(ctx, provider.Address(),
		decimal.NewFromFloat(0.01),
		decimal.NewFromFloat(5.0),
		remitmd.WithStreamPermit(permit),
	)
	if err != nil {
		logFail(flow, fmt.Sprintf("CreateStream: %v", err))
		return
	}
	if stream.ID == "" {
		logFail(flow, "stream ID should not be empty")
		return
	}
	if stream.TxHash != "" {
		logTx(flow, "open", stream.TxHash)
	}

	waitForBalanceChange(agent.Address(), payerBefore)

	logInfo("  Waiting 5 seconds for stream accrual...")
	time.Sleep(5 * time.Second)

	// Close stream with retries for Ponder indexer lag
	var closed *remitmd.Transaction
	for attempt := 0; attempt < 20; attempt++ {
		closed, err = agent.CloseStream(ctx, stream.ID)
		if err == nil {
			break
		}
		if attempt < 19 {
			logInfo(fmt.Sprintf("  CloseStream attempt %d failed: %v, retrying...", attempt+1, err))
			time.Sleep(5 * time.Second)
		}
	}
	if err != nil {
		logFail(flow, fmt.Sprintf("CloseStream: %v", err))
		return
	}
	if closed.TxHash != "" {
		logTx(flow, "close", closed.TxHash)
	}
	logPass(flow, fmt.Sprintf("stream_id=%s", stream.ID))
}

// ─── Flow 5: Bounty ──────────────────────────────────────────────────────────

func flowBounty(agent, provider *testWallet, permitNonce *int64) {
	flow := "5. Bounty"
	ctx := context.Background()

	c, err := fetchContracts()
	if err != nil {
		logFail(flow, err.Error())
		return
	}

	permit, err := signUSDCPermit(agent.key,
		crypto.PubkeyToAddress(agent.key.PublicKey),
		common.HexToAddress(c.Bounty),
		big.NewInt(6_000_000), // $6 USDC
		big.NewInt(*permitNonce),
		big.NewInt(time.Now().Unix()+3600),
	)
	*permitNonce++
	if err != nil {
		logFail(flow, err.Error())
		return
	}

	agentBefore := getUsdcBalance(agent.Address())

	deadline := time.Now().Unix() + 3600
	bounty, err := agent.CreateBounty(ctx,
		decimal.NewFromFloat(5.0),
		"acceptance-bounty-test",
		deadline,
		remitmd.WithBountyPermit(permit),
	)
	if err != nil {
		logFail(flow, fmt.Sprintf("CreateBounty: %v", err))
		return
	}
	if bounty.ID == "" {
		logFail(flow, "bounty ID should not be empty")
		return
	}
	if bounty.TxHash != "" {
		logTx(flow, "post", bounty.TxHash)
	}

	waitForBalanceChange(agent.Address(), agentBefore)

	evidenceHash := "0x" + hex.EncodeToString(crypto.Keccak256([]byte("test evidence")))
	sub, err := provider.SubmitBounty(ctx, bounty.ID, evidenceHash)
	if err != nil {
		logFail(flow, fmt.Sprintf("SubmitBounty: %v", err))
		return
	}
	logInfo(fmt.Sprintf("  Submission: id=%d, status=%s", sub.ID, sub.Status))

	time.Sleep(5 * time.Second)

	awarded, err := agent.AwardBounty(ctx, bounty.ID, sub.ID)
	if err != nil {
		logFail(flow, fmt.Sprintf("AwardBounty: %v", err))
		return
	}
	if awarded.TxHash != "" {
		logTx(flow, "award", awarded.TxHash)
	}
	logPass(flow, fmt.Sprintf("bounty_id=%s", bounty.ID))
}

// ─── Flow 6: Deposit ─────────────────────────────────────────────────────────

func flowDeposit(agent, provider *testWallet, permitNonce *int64) {
	flow := "6. Deposit"
	ctx := context.Background()

	c, err := fetchContracts()
	if err != nil {
		logFail(flow, err.Error())
		return
	}

	permit, err := signUSDCPermit(agent.key,
		crypto.PubkeyToAddress(agent.key.PublicKey),
		common.HexToAddress(c.Deposit),
		big.NewInt(6_000_000), // $6 USDC
		big.NewInt(*permitNonce),
		big.NewInt(time.Now().Unix()+3600),
	)
	*permitNonce++
	if err != nil {
		logFail(flow, err.Error())
		return
	}

	payerBefore := getUsdcBalance(agent.Address())

	deposit, err := agent.PlaceDeposit(ctx, provider.Address(),
		decimal.NewFromFloat(5.0),
		1*time.Hour,
		remitmd.WithDepositPermit(permit),
	)
	if err != nil {
		logFail(flow, fmt.Sprintf("PlaceDeposit: %v", err))
		return
	}
	if deposit.ID == "" {
		logFail(flow, "deposit ID should not be empty")
		return
	}
	if deposit.TxHash != "" {
		logTx(flow, "place", deposit.TxHash)
	}

	waitForBalanceChange(agent.Address(), payerBefore)

	returned, err := provider.ReturnDeposit(ctx, deposit.ID)
	if err != nil {
		logFail(flow, fmt.Sprintf("ReturnDeposit: %v", err))
		return
	}
	if returned != nil && returned.TxHash != "" {
		logTx(flow, "return", returned.TxHash)
	}
	logPass(flow, fmt.Sprintf("deposit_id=%s", deposit.ID))
}

// ─── Flow 7: x402 Weather ────────────────────────────────────────────────────

func flowX402Weather(agent *testWallet) {
	flow := "7. x402 Weather"

	// Step 1: Hit the paywall
	resp, err := http.Get(apiBase + "/x402/demo")
	if err != nil {
		logFail(flow, fmt.Sprintf("GET /x402/demo: %v", err))
		return
	}
	resp.Body.Close()
	if resp.StatusCode != 402 {
		logFail(flow, fmt.Sprintf("expected 402, got %d", resp.StatusCode))
		return
	}

	// Parse X-Payment headers
	scheme := resp.Header.Get("X-Payment-Scheme")
	if scheme == "" {
		scheme = "exact"
	}
	network := resp.Header.Get("X-Payment-Network")
	if network == "" {
		network = fmt.Sprintf("eip155:%d", chainID.Int64())
	}
	amountStr := resp.Header.Get("X-Payment-Amount")
	if amountStr == "" {
		amountStr = "5000000"
	}
	asset := resp.Header.Get("X-Payment-Asset")
	if asset == "" {
		asset = usdcAddress.Hex()
	}
	payTo := resp.Header.Get("X-Payment-PayTo")

	amountRaw, _ := new(big.Int).SetString(amountStr, 10)
	if amountRaw == nil {
		amountRaw = big.NewInt(5_000_000)
	}
	amountUsdc := float64(amountRaw.Int64()) / 1e6
	logInfo(fmt.Sprintf("  Paywall: %s | $%.2f USDC | network=%s", scheme, amountUsdc, network))

	// Step 2: Sign EIP-3009 TransferWithAuthorization
	now := time.Now().Unix()
	validBefore := now + 300

	var nonceBytes [32]byte
	if _, err := rand.Read(nonceBytes[:]); err != nil {
		logFail(flow, fmt.Sprintf("generate nonce: %v", err))
		return
	}

	from := crypto.PubkeyToAddress(agent.key.PublicKey)
	signature, err := signEIP3009(
		agent.key,
		from,
		common.HexToAddress(payTo),
		amountRaw,
		big.NewInt(0),
		big.NewInt(validBefore),
		nonceBytes,
	)
	if err != nil {
		logFail(flow, fmt.Sprintf("signEIP3009: %v", err))
		return
	}

	nonceHex := "0x" + hex.EncodeToString(nonceBytes[:])

	// Step 3: Settle on-chain via POST
	settleBody := map[string]interface{}{
		"paymentPayload": map[string]interface{}{
			"scheme":      scheme,
			"network":     network,
			"x402Version": 1,
			"payload": map[string]interface{}{
				"signature": signature,
				"authorization": map[string]interface{}{
					"from":        from.Hex(),
					"to":          payTo,
					"value":       amountStr,
					"validAfter":  "0",
					"validBefore": fmt.Sprintf("%d", validBefore),
					"nonce":       nonceHex,
				},
			},
		},
		"paymentRequired": map[string]interface{}{
			"scheme":            scheme,
			"network":           network,
			"amount":            amountStr,
			"asset":             asset,
			"payTo":             payTo,
			"maxTimeoutSeconds": 300,
		},
	}

	settleJSON, _ := json.Marshal(settleBody)

	c, cerr := fetchContracts()
	if cerr != nil {
		logFail(flow, cerr.Error())
		return
	}
	authSig, authAgent, authTs, authNonce, authErr := signAPIAuth(agent.key, "POST", "/api/v1/x402/settle", c.Router)
	if authErr != nil {
		logFail(flow, fmt.Sprintf("signAPIAuth: %v", authErr))
		return
	}

	settleReq, _ := http.NewRequest("POST", apiBase+"/x402/settle", strings.NewReader(string(settleJSON)))
	settleReq.Header.Set("Content-Type", "application/json")
	settleReq.Header.Set("X-Remit-Signature", authSig)
	settleReq.Header.Set("X-Remit-Agent", authAgent)
	settleReq.Header.Set("X-Remit-Timestamp", authTs)
	settleReq.Header.Set("X-Remit-Nonce", authNonce)
	settleResp, err := http.DefaultClient.Do(settleReq)
	if err != nil {
		logFail(flow, fmt.Sprintf("POST /x402/settle: %v", err))
		return
	}
	defer settleResp.Body.Close()

	settleBytes, _ := io.ReadAll(settleResp.Body)
	var settleResult map[string]interface{}
	json.Unmarshal(settleBytes, &settleResult)

	txHash, _ := settleResult["transactionHash"].(string)
	if txHash == "" {
		logFail(flow, fmt.Sprintf("settle returned no tx_hash: %s", string(settleBytes)))
		return
	}
	logTx(flow, "settle", txHash)

	// Step 4: Fetch weather data with payment proof
	req, _ := http.NewRequest("GET", apiBase+"/x402/demo", nil)
	req.Header.Set("X-Payment-Response", txHash)
	weatherResp, err := http.DefaultClient.Do(req)
	if err != nil {
		logFail(flow, fmt.Sprintf("GET /x402/demo with payment: %v", err))
		return
	}
	defer weatherResp.Body.Close()

	if weatherResp.StatusCode != 200 {
		logFail(flow, fmt.Sprintf("weather fetch returned %d", weatherResp.StatusCode))
		return
	}

	var weather map[string]interface{}
	json.NewDecoder(weatherResp.Body).Decode(&weather)

	// Display weather report
	loc, _ := weather["location"].(map[string]interface{})
	cur, _ := weather["current"].(map[string]interface{})
	if loc == nil {
		loc = map[string]interface{}{}
	}
	if cur == nil {
		cur = map[string]interface{}{}
	}
	cond, _ := cur["condition"].(map[string]interface{})
	if cond == nil {
		cond = map[string]interface{}{}
	}

	city := strOr(loc["name"], "Unknown")
	region := strings.Trim(fmt.Sprintf("%s, %s", strOr(loc["region"], ""), strOr(loc["country"], "")), ", ")
	tempF := strOr(cur["temp_f"], "?")
	tempC := strOr(cur["temp_c"], "?")
	condition := strOr(cond["text"], strOr(cur["condition"], "Unknown"))
	humidity := strOr(cur["humidity"], "?")
	windMph := strOr(cur["wind_mph"], strOr(cur["wind_kph"], "?"))
	windDir := strOr(cur["wind_dir"], "")

	fmt.Println()
	fmt.Printf("%s%s%s%s%s\n", cyan, "┌─────────────────────────────────────────────┐", reset, "", "")
	fmt.Printf("%s│%s  %sx402 Weather Report%s (paid $%.2f USDC)   %s│%s\n", cyan, reset, bold, reset, amountUsdc, cyan, reset)
	fmt.Printf("%s├─────────────────────────────────────────────┤%s\n", cyan, reset)
	fmt.Printf("%s│%s  City:        %-29s%s│%s\n", cyan, reset, city, cyan, reset)
	fmt.Printf("%s│%s  Region:      %-29s%s│%s\n", cyan, reset, region, cyan, reset)
	fmt.Printf("%s│%s  Temperature: %s°F / %s°C%-19s%s│%s\n", cyan, reset, tempF, tempC, "", cyan, reset)
	fmt.Printf("%s│%s  Condition:   %-29s%s│%s\n", cyan, reset, condition, cyan, reset)
	fmt.Printf("%s│%s  Humidity:    %s%%%-28s%s│%s\n", cyan, reset, humidity, "", cyan, reset)
	fmt.Printf("%s│%s  Wind:        %s mph %s%-22s%s│%s\n", cyan, reset, windMph, windDir, "", cyan, reset)
	fmt.Printf("%s└─────────────────────────────────────────────┘%s\n", cyan, reset)
	fmt.Println()

	logPass(flow, fmt.Sprintf("city=%s, tx=%s...", city, txHash[:18]))
}

func strOr(v interface{}, fallback string) string {
	if v == nil {
		return fallback
	}
	switch s := v.(type) {
	case string:
		if s == "" {
			return fallback
		}
		return s
	case float64:
		return fmt.Sprintf("%.0f", s)
	default:
		return fmt.Sprintf("%v", v)
	}
}

// ─── Flow 8: AP2 Discovery ──────────────────────────────────────────────────

func flowAP2Discovery() {
	flow := "8. AP2 Discovery"
	ctx := context.Background()

	card, err := remitmd.DiscoverAgent(ctx, apiURL)
	if err != nil {
		logFail(flow, fmt.Sprintf("DiscoverAgent: %v", err))
		return
	}

	fmt.Println()
	fmt.Printf("%s┌─────────────────────────────────────────────┐%s\n", cyan, reset)
	fmt.Printf("%s│%s  %sA2A Agent Card%s                            %s│%s\n", cyan, reset, bold, reset, cyan, reset)
	fmt.Printf("%s├─────────────────────────────────────────────┤%s\n", cyan, reset)
	fmt.Printf("%s│%s  Name:     %-32s%s│%s\n", cyan, reset, card.Name, cyan, reset)
	fmt.Printf("%s│%s  Version:  %-32s%s│%s\n", cyan, reset, card.Version, cyan, reset)
	fmt.Printf("%s│%s  Protocol: %-32s%s│%s\n", cyan, reset, card.ProtocolVersion, cyan, reset)
	urlDisplay := card.URL
	if len(urlDisplay) > 32 {
		urlDisplay = urlDisplay[:32]
	}
	fmt.Printf("%s│%s  URL:      %-32s%s│%s\n", cyan, reset, urlDisplay, cyan, reset)
	if len(card.Skills) > 0 {
		fmt.Printf("%s│%s  Skills:   %d total%25s%s│%s\n", cyan, reset, len(card.Skills), "", cyan, reset)
		limit := 5
		if len(card.Skills) < limit {
			limit = len(card.Skills)
		}
		for _, s := range card.Skills[:limit] {
			name := s.Name
			if len(name) > 38 {
				name = name[:38]
			}
			fmt.Printf("%s│%s    - %-38s%s│%s\n", cyan, reset, name, cyan, reset)
		}
	}
	if card.X402.SettleEndpoint != "" {
		x402Info := fmt.Sprintf("settle=%s", card.X402.SettleEndpoint)
		if len(x402Info) > 32 {
			x402Info = x402Info[:32]
		}
		fmt.Printf("%s│%s  x402:     %-32s%s│%s\n", cyan, reset, x402Info, cyan, reset)
	}
	exts := "none"
	if len(card.Capabilities.Extensions) > 0 {
		extNames := make([]string, 0, len(card.Capabilities.Extensions))
		for _, e := range card.Capabilities.Extensions {
			parts := strings.Split(e.URI, "/")
			extNames = append(extNames, parts[len(parts)-1])
		}
		exts = strings.Join(extNames, ", ")
		if len(exts) > 16 {
			exts = exts[:16]
		}
	}
	fmt.Printf("%s│%s  Caps:     streaming=%v, exts=%s%3s%s│%s\n", cyan, reset, card.Capabilities.Streaming, exts, "", cyan, reset)
	fmt.Printf("%s└─────────────────────────────────────────────┘%s\n", cyan, reset)
	fmt.Println()

	if card.Name == "" {
		logFail(flow, "agent card should have a name")
		return
	}
	logPass(flow, fmt.Sprintf("name=%s", card.Name))
}

// ─── Flow 9: AP2 Payment ────────────────────────────────────────────────────

func flowAP2Payment(agent, provider *testWallet) {
	flow := "9. AP2 Payment"
	ctx := context.Background()

	card, err := remitmd.DiscoverAgent(ctx, apiURL)
	if err != nil {
		logFail(flow, fmt.Sprintf("DiscoverAgent: %v", err))
		return
	}

	signer, err := remitmd.NewPrivateKeySigner("0x" + hex.EncodeToString(crypto.FromECDSA(agent.key)))
	if err != nil {
		logFail(flow, fmt.Sprintf("NewPrivateKeySigner: %v", err))
		return
	}

	a2a, err := remitmd.A2AClientFromCard(card, signer, "base-sepolia")
	if err != nil {
		logFail(flow, fmt.Sprintf("A2AClientFromCard: %v", err))
		return
	}

	task, err := a2a.Send(ctx, remitmd.SendOptions{
		To:     provider.Address(),
		Amount: 1.0,
		Memo:   "acceptance-ap2-payment",
		Mandate: &remitmd.IntentMandate{
			MandateID: randomHex(16),
			ExpiresAt: "2099-12-31T23:59:59Z",
			Issuer:    agent.Address(),
		},
	})
	if err != nil {
		errMsg := err.Error()
		if strings.Contains(errMsg, "401") || strings.Contains(errMsg, "403") || strings.Contains(strings.ToLower(errMsg), "auth") {
			fmt.Printf("%s[SKIP]%s %s — AP2 endpoint may not be available on testnet: %v\n", yellow, reset, flow, err)
			results = append(results, result{flow, "SKIP"})
			return
		}
		logFail(flow, fmt.Sprintf("Send: %v", err))
		return
	}
	if task.ID == "" {
		fmt.Printf("%s[SKIP]%s %s — AP2 task has no ID (endpoint may not be available on testnet)\n", yellow, reset, flow)
		results = append(results, result{flow, "SKIP"})
		return
	}

	txHash := remitmd.GetTaskTxHash(task)
	if txHash != "" {
		logTx(flow, "a2a-pay", txHash)
	}

	// Verify persistence
	fetched, err := a2a.GetTask(ctx, task.ID)
	if err != nil {
		logFail(flow, fmt.Sprintf("GetTask: %v", err))
		return
	}
	if fetched.ID != task.ID {
		logFail(flow, fmt.Sprintf("fetched task id mismatch: %s != %s", fetched.ID, task.ID))
		return
	}

	logPass(flow, fmt.Sprintf("task_id=%s, state=%s", task.ID, task.Status.State))
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

func randomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// ─── Main ─────────────────────────────────────────────────────────────────────

func main() {
	fmt.Println()
	fmt.Printf("%sGo SDK — 9 Flow Acceptance Suite%s\n", bold, reset)
	fmt.Printf("  API: %s\n", apiURL)
	fmt.Printf("  RPC: %s\n", rpcURL)
	fmt.Println()

	// Setup wallets
	logInfo("Creating agent wallet...")
	agent, err := createWallet()
	if err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: create agent wallet: %v\n", err)
		os.Exit(1)
	}
	logInfo(fmt.Sprintf("  Agent:    %s", agent.Address()))

	logInfo("Creating provider wallet...")
	provider, err := createWallet()
	if err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: create provider wallet: %v\n", err)
		os.Exit(1)
	}
	logInfo(fmt.Sprintf("  Provider: %s", provider.Address()))

	logInfo("Minting $100 USDC to agent...")
	if err := fundWallet(agent, 100); err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: fund agent: %v\n", err)
		os.Exit(1)
	}
	bal := getUsdcBalance(agent.Address())
	logInfo(fmt.Sprintf("  Agent balance: $%.2f", bal))

	logInfo("Minting $100 USDC to provider...")
	if err := fundWallet(provider, 100); err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: fund provider: %v\n", err)
		os.Exit(1)
	}
	bal2 := getUsdcBalance(provider.Address())
	logInfo(fmt.Sprintf("  Provider balance: $%.2f", bal2))
	fmt.Println()

	// Permit nonce counter — each permit consumed on-chain increments the nonce
	permitNonce := int64(0)

	// Run all 9 flows
	type flowFn struct {
		name string
		fn   func()
	}

	flows := []flowFn{
		{"1. Direct Payment", func() { flowDirect(agent, provider, &permitNonce) }},
		{"2. Escrow", func() { flowEscrow(agent, provider, &permitNonce) }},
		{"3. Metered Tab", func() { flowTab(agent, provider, &permitNonce) }},
		{"4. Stream", func() { flowStream(agent, provider, &permitNonce) }},
		{"5. Bounty", func() { flowBounty(agent, provider, &permitNonce) }},
		{"6. Deposit", func() { flowDeposit(agent, provider, &permitNonce) }},
		{"7. x402 Weather", func() { flowX402Weather(agent) }},
		{"8. AP2 Discovery", func() { flowAP2Discovery() }},
		{"9. AP2 Payment", func() { flowAP2Payment(agent, provider) }},
	}

	for _, f := range flows {
		func() {
			defer func() {
				if r := recover(); r != nil {
					logFail(f.name, fmt.Sprintf("panic: %v", r))
				}
			}()
			f.fn()
		}()
	}

	// Summary
	passed := 0
	failed := 0
	for _, r := range results {
		if r.status == "PASS" {
			passed++
		} else {
			failed++
		}
	}
	skipped := 9 - passed - failed

	fmt.Println()
	fmt.Printf("%sGo Summary: %s%d passed%s, %s%d failed%s / 9 flows\n",
		bold, green, passed, reset, red, failed, reset)

	summary, _ := json.Marshal(map[string]int{
		"passed":  passed,
		"failed":  failed,
		"skipped": skipped,
	})
	fmt.Println(string(summary))

	if failed > 0 {
		os.Exit(1)
	}
}
