package remitmd

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// AllowanceExceededError is raised when an x402 payment amount exceeds the
// configured auto-pay limit.
type AllowanceExceededError struct {
	AmountUsdc float64
	LimitUsdc  float64
}

func (e *AllowanceExceededError) Error() string {
	return fmt.Sprintf("x402 payment %.6f USDC exceeds auto-pay limit %.6f USDC", e.AmountUsdc, e.LimitUsdc)
}

// X402Response wraps the HTTP response and the decoded PAYMENT-REQUIRED header
// from the last 402 interaction.
type X402Response struct {
	Response    *http.Response
	LastPayment *PaymentRequired
}

// PaymentRequired is the decoded shape of the PAYMENT-REQUIRED header (V2).
type PaymentRequired struct {
	Scheme            string `json:"scheme"`
	Network           string `json:"network"`
	Amount            string `json:"amount"`
	Asset             string `json:"asset"`
	PayTo             string `json:"payTo"`
	MaxTimeoutSeconds int    `json:"maxTimeoutSeconds,omitempty"`
	Resource          string `json:"resource,omitempty"`
	Description       string `json:"description,omitempty"`
	MimeType          string `json:"mimeType,omitempty"`
}

// X402Client is a consumer-side HTTP client that auto-pays x402 Payment Required
// responses by signing EIP-3009 TransferWithAuthorization.
type X402Client struct {
	wallet         *Wallet
	MaxAutoPayUsdc float64
	httpClient     *http.Client
}

// NewX402Client creates an X402Client from a Wallet.
// maxAutoPayUsdc sets the maximum USDC to auto-pay per request (default: 0.10).
func NewX402Client(wallet *Wallet, maxAutoPayUsdc ...float64) *X402Client {
	limit := 0.10
	if len(maxAutoPayUsdc) > 0 && maxAutoPayUsdc[0] > 0 {
		limit = maxAutoPayUsdc[0]
	}
	return &X402Client{
		wallet:         wallet,
		MaxAutoPayUsdc: limit,
		httpClient:     &http.Client{Timeout: 30 * time.Second},
	}
}

// Fetch makes a GET request to the given URL. If a 402 Payment Required is
// returned, it signs an EIP-3009 authorization and retries with a
// PAYMENT-SIGNATURE header.
func (c *X402Client) Fetch(ctx context.Context, url string) (*X402Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("x402: create request: %w", err)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("x402: request failed: %w", err)
	}

	if resp.StatusCode != http.StatusPaymentRequired {
		return &X402Response{Response: resp}, nil
	}

	return c.handle402(ctx, url, resp)
}

func (c *X402Client) handle402(ctx context.Context, url string, resp *http.Response) (*X402Response, error) {
	defer resp.Body.Close()

	// 1. Decode PAYMENT-REQUIRED header (case-insensitive).
	raw := resp.Header.Get("payment-required")
	if raw == "" {
		raw = resp.Header.Get("PAYMENT-REQUIRED")
	}
	if raw == "" {
		return nil, fmt.Errorf("x402: 402 response missing PAYMENT-REQUIRED header")
	}

	decoded, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return nil, fmt.Errorf("x402: decode PAYMENT-REQUIRED: %w", err)
	}

	var required PaymentRequired
	if err := json.Unmarshal(decoded, &required); err != nil {
		return nil, fmt.Errorf("x402: parse PAYMENT-REQUIRED: %w", err)
	}

	// 2. Only "exact" scheme is supported.
	if required.Scheme != "exact" {
		return nil, fmt.Errorf("x402: unsupported scheme: %s", required.Scheme)
	}

	// 3. Check auto-pay limit.
	amountBaseUnits := new(big.Int)
	amountBaseUnits.SetString(required.Amount, 10)
	amountUsdc := float64(amountBaseUnits.Int64()) / 1_000_000.0
	if amountUsdc > c.MaxAutoPayUsdc {
		return nil, &AllowanceExceededError{AmountUsdc: amountUsdc, LimitUsdc: c.MaxAutoPayUsdc}
	}

	// 4. Parse chainId from CAIP-2 network string (e.g. "eip155:84532" -> 84532).
	parts := strings.Split(required.Network, ":")
	if len(parts) < 2 {
		return nil, fmt.Errorf("x402: invalid network format: %s", required.Network)
	}
	chainID, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return nil, fmt.Errorf("x402: parse chainId: %w", err)
	}

	// 5. Build EIP-3009 TransferWithAuthorization fields.
	nowSecs := time.Now().Unix()
	maxTimeout := required.MaxTimeoutSeconds
	if maxTimeout <= 0 {
		maxTimeout = 60
	}
	validBefore := nowSecs + int64(maxTimeout)

	var nonceBytes [32]byte
	if _, err := rand.Read(nonceBytes[:]); err != nil {
		return nil, fmt.Errorf("x402: generate nonce: %w", err)
	}
	nonce := "0x" + hex.EncodeToString(nonceBytes[:])

	// 6. Sign EIP-712 typed data (EIP-3009 TransferWithAuthorization).
	digest := computeEIP3009Digest(
		new(big.Int).SetInt64(chainID),
		common.HexToAddress(required.Asset),
		c.wallet.signer.Address(),
		common.HexToAddress(required.PayTo),
		amountBaseUnits,
		big.NewInt(0),
		big.NewInt(validBefore),
		nonceBytes,
	)

	sig, err := c.wallet.signer.Sign(digest)
	if err != nil {
		return nil, fmt.Errorf("x402: sign: %w", err)
	}
	signature := "0x" + hex.EncodeToString(sig)

	// 7. Build PAYMENT-SIGNATURE JSON payload.
	paymentPayload := map[string]any{
		"scheme":      required.Scheme,
		"network":     required.Network,
		"x402Version": 1,
		"payload": map[string]any{
			"signature": signature,
			"authorization": map[string]any{
				"from":        c.wallet.signer.Address().Hex(),
				"to":          required.PayTo,
				"value":       required.Amount,
				"validAfter":  "0",
				"validBefore": strconv.FormatInt(validBefore, 10),
				"nonce":       nonce,
			},
		},
	}

	payloadJSON, err := json.Marshal(paymentPayload)
	if err != nil {
		return nil, fmt.Errorf("x402: marshal payment payload: %w", err)
	}
	paymentHeader := base64.StdEncoding.EncodeToString(payloadJSON)

	// 8. Retry with PAYMENT-SIGNATURE header.
	retryReq, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("x402: create retry request: %w", err)
	}
	retryReq.Header.Set("PAYMENT-SIGNATURE", paymentHeader)

	retryResp, err := c.httpClient.Do(retryReq)
	if err != nil {
		return nil, fmt.Errorf("x402: retry request failed: %w", err)
	}

	return &X402Response{
		Response:    retryResp,
		LastPayment: &required,
	}, nil
}

// EIP-3009 type hash
var transferWithAuthorizationTypeHash = crypto.Keccak256Hash(
	[]byte("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"),
)

// eip3009Type defines the ABI encoding for TransferWithAuthorization struct.
var eip3009Type = abi.Arguments{
	{Type: mustType("bytes32")}, // typeHash
	{Type: mustType("address")}, // from
	{Type: mustType("address")}, // to
	{Type: mustType("uint256")}, // value
	{Type: mustType("uint256")}, // validAfter
	{Type: mustType("uint256")}, // validBefore
	{Type: mustType("bytes32")}, // nonce
}

// computeEIP3009Digest computes the EIP-712 digest for EIP-3009
// TransferWithAuthorization (used by USDC).
func computeEIP3009Digest(
	chainID *big.Int,
	usdcAddr common.Address,
	from common.Address,
	to common.Address,
	value *big.Int,
	validAfter *big.Int,
	validBefore *big.Int,
	nonce [32]byte,
) [32]byte {
	// USDC domain separator (name="USD Coin", version="2")
	domain := computeUsdcDomainSeparator(chainID, usdcAddr)

	packed, _ := eip3009Type.Pack(
		transferWithAuthorizationTypeHash,
		from, to, value, validAfter, validBefore, nonce,
	)
	structHash := crypto.Keccak256Hash(packed)

	return crypto.Keccak256Hash(
		append([]byte("\x19\x01"), append(domain[:], structHash[:]...)...),
	)
}
