package remitmd

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

const (
	defaultTimeout = 30 * time.Second
	maxRetries     = 3
	retryBaseDelay = 500 * time.Millisecond
)

// remitTransport is the internal interface for making API calls.
// httpClient implements it for real requests; mockTransport for tests.
type remitTransport interface {
	post(ctx context.Context, path string, body any, dst any) error
	get(ctx context.Context, path string, dst any) error
}

// chainConfig maps chain identifiers to their API endpoints.
var chainConfig = map[string]struct {
	ChainID ChainID
	APIURL  string
	Testnet bool
}{
	"base":         {ChainID: ChainBase, APIURL: "https://api.remit.md", Testnet: false},
	"base-sepolia": {ChainID: ChainBaseSep, APIURL: "https://testnet.remit.md", Testnet: true},
	"arbitrum":     {ChainID: ChainArbitrum, APIURL: "https://arb.remit.md", Testnet: false},
	"optimism":     {ChainID: ChainOptimism, APIURL: "https://op.remit.md", Testnet: false},
}

// httpClient is the authenticated HTTP client used by Wallet.
type httpClient struct {
	baseURL       string
	chainID       ChainID
	routerAddress common.Address
	signer        Signer
	httpClient    *http.Client
}

func newHTTPClient(baseURL string, chainID ChainID, routerAddress common.Address, signer Signer) *httpClient {
	return &httpClient{
		baseURL:       baseURL,
		chainID:       chainID,
		routerAddress: routerAddress,
		signer:        signer,
		httpClient: &http.Client{
			Timeout: defaultTimeout,
		},
	}
}

// post sends an authenticated POST request and decodes the JSON response into dst.
func (c *httpClient) post(ctx context.Context, path string, body any, dst any) error {
	return c.do(ctx, http.MethodPost, path, body, dst)
}

// get sends an authenticated GET request and decodes the JSON response into dst.
func (c *httpClient) get(ctx context.Context, path string, dst any) error {
	return c.do(ctx, http.MethodGet, path, nil, dst)
}

func (c *httpClient) do(ctx context.Context, method, path string, body any, dst any) error {
	var bodyBytes []byte
	var err error
	if body != nil {
		bodyBytes, err = json.Marshal(body)
		if err != nil {
			return fmt.Errorf("marshal request: %w", err)
		}
	}

	var lastErr error
	for attempt := range maxRetries {
		if attempt > 0 {
			delay := retryBaseDelay * time.Duration(1<<uint(attempt-1))
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(delay):
			}
		}

		lastErr = c.attempt(ctx, method, path, bodyBytes, dst)
		if lastErr == nil {
			return nil
		}

		// Only retry on network errors and 5xx responses.
		if re, ok := lastErr.(*RemitError); ok {
			if re.Code == ErrCodeRateLimited || re.Code == ErrCodeServerError {
				continue
			}
			return lastErr // 4xx errors are not retryable
		}
		// Network error — retry
	}
	return lastErr
}

func (c *httpClient) attempt(ctx context.Context, method, path string, bodyBytes []byte, dst any) error {
	url := c.baseURL + path

	var bodyReader io.Reader
	if bodyBytes != nil {
		bodyReader = bytes.NewReader(bodyBytes)
	}

	req, err := http.NewRequestWithContext(ctx, method, url, bodyReader)
	if err != nil {
		return remitErr(ErrCodeNetworkError, fmt.Sprintf("create request: %s", err), nil)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	if err := c.sign(req, bodyBytes); err != nil {
		return err
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return remitErr(ErrCodeNetworkError,
			fmt.Sprintf("request to %s failed: %s. Check network connectivity.", url, err),
			map[string]any{"url": url},
		)
	}
	defer resp.Body.Close()

	respBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return remitErr(ErrCodeNetworkError, "read response body failed", nil)
	}

	if resp.StatusCode >= 400 {
		return c.parseAPIError(resp.StatusCode, respBytes)
	}

	if dst != nil {
		if err := json.Unmarshal(respBytes, dst); err != nil {
			return remitErr(ErrCodeServerError,
				fmt.Sprintf("unexpected response format: %s", err),
				map[string]any{"body": string(respBytes[:min(len(respBytes), 200)])},
			)
		}
	}
	return nil
}

// sign adds EIP-712 authentication headers to the request.
//
// Sets X-Remit-Agent, X-Remit-Nonce, X-Remit-Timestamp, and X-Remit-Signature.
// Matches the server's auth middleware (APIRequest struct type).
func (c *httpClient) sign(req *http.Request, body []byte) error {
	var nonceBytes [32]byte
	if _, err := rand.Read(nonceBytes[:]); err != nil {
		return fmt.Errorf("generate nonce: %w", err)
	}
	nonce := "0x" + hex.EncodeToString(nonceBytes[:])
	timestamp := uint64(time.Now().Unix())

	chainID := new(big.Int).SetUint64(uint64(c.chainID))
	digest := computeRequestDigest(chainID, c.routerAddress, req.Method, req.URL.Path, timestamp, nonceBytes)

	sig, err := c.signer.Sign(digest)
	if err != nil {
		return fmt.Errorf("sign request: %w", err)
	}

	req.Header.Set("X-Remit-Agent", c.signer.Address().Hex())
	req.Header.Set("X-Remit-Nonce", nonce)
	req.Header.Set("X-Remit-Timestamp", fmt.Sprintf("%d", timestamp))
	req.Header.Set("X-Remit-Signature", "0x"+hex.EncodeToString(sig))
	return nil
}

// apiErrorResponse is the JSON error shape returned by the remit.md API.
type apiErrorResponse struct {
	Code    string         `json:"code"`
	Message string         `json:"message"`
	Context map[string]any `json:"context,omitempty"`
}

func (c *httpClient) parseAPIError(statusCode int, body []byte) *RemitError {
	var apiErr apiErrorResponse
	if err := json.Unmarshal(body, &apiErr); err != nil || apiErr.Code == "" {
		// Fallback for non-standard error responses
		if statusCode == 429 {
			return remitErr(ErrCodeRateLimited, "rate limit exceeded — reduce request frequency", nil)
		}
		if statusCode >= 500 {
			return remitErr(ErrCodeServerError, fmt.Sprintf("server error (HTTP %d)", statusCode), nil)
		}
		return remitErr(ErrCodeServerError, fmt.Sprintf("unexpected error (HTTP %d): %s", statusCode, string(body)), nil)
	}
	return remitErr(apiErr.Code, apiErr.Message, apiErr.Context)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
