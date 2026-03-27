package remitmd

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/ethereum/go-ethereum/common"
)

// HttpSigner implements Signer by delegating to a local HTTP signing server.
// The signer server holds the encrypted key; this adapter only needs a bearer
// token and URL.
//
// Create with NewHttpSigner, which fetches and caches the wallet address:
//
//	signer, err := remitmd.NewHttpSigner("http://127.0.0.1:7402", "rmit_sk_...")
//	wallet, err := remitmd.NewWalletWithSigner(signer)
type HttpSigner struct {
	url     string
	token   string
	address common.Address
}

// addressResponse is the JSON shape returned by GET /address.
type addressResponse struct {
	Address string `json:"address"`
}

// signDigestRequest is the JSON body sent to POST /sign/digest.
type signDigestRequest struct {
	Digest string `json:"digest"`
}

// signDigestResponse is the JSON shape returned by POST /sign/digest.
type signDigestResponse struct {
	Signature string `json:"signature"`
}

// signerErrorResponse is the JSON shape returned on error responses.
type signerErrorResponse struct {
	Error  string `json:"error"`
	Reason string `json:"reason"`
}

// NewHttpSigner creates an HttpSigner by fetching the wallet address from
// GET /address on the signer server. The address is cached for all subsequent
// calls to Address().
//
// The bearer token is stored privately and never appears in error messages.
func NewHttpSigner(url, token string) (*HttpSigner, error) {
	url = strings.TrimRight(url, "/")

	req, err := http.NewRequest("GET", url+"/address", nil)
	if err != nil {
		return nil, remitErr(ErrCodeNetworkError,
			fmt.Sprintf("HttpSigner: failed to build request for %s/address", url),
			map[string]any{"url": url},
		)
	}
	req.Header.Set("Authorization", "Bearer "+token)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, remitErr(ErrCodeNetworkError,
			fmt.Sprintf("HttpSigner: cannot reach signer server at %s: %s", url, err),
			map[string]any{"url": url},
		)
	}
	defer resp.Body.Close()

	if resp.StatusCode == 401 {
		return nil, remitErr(ErrCodeUnauthorized,
			"HttpSigner: unauthorized -- check your REMIT_SIGNER_TOKEN",
			nil,
		)
	}
	if resp.StatusCode == 403 {
		reason := readErrorReason(resp.Body)
		return nil, remitErr("POLICY_DENIED",
			fmt.Sprintf("HttpSigner: policy denied -- %s", reason),
			map[string]any{"reason": reason},
		)
	}
	if resp.StatusCode != 200 {
		reason := readErrorReason(resp.Body)
		return nil, remitErr(ErrCodeServerError,
			fmt.Sprintf("HttpSigner: GET /address failed (%d): %s", resp.StatusCode, reason),
			map[string]any{"status": resp.StatusCode},
		)
	}

	var addrResp addressResponse
	if err := json.NewDecoder(resp.Body).Decode(&addrResp); err != nil {
		return nil, remitErr(ErrCodeServerError,
			fmt.Sprintf("HttpSigner: GET /address returned invalid JSON: %s", err),
			nil,
		)
	}
	if addrResp.Address == "" {
		return nil, remitErr(ErrCodeServerError,
			"HttpSigner: GET /address returned no address",
			nil,
		)
	}

	return &HttpSigner{
		url:     url,
		token:   token,
		address: common.HexToAddress(addrResp.Address),
	}, nil
}

// Sign sends the digest to POST /sign/digest and returns the 65-byte signature.
func (h *HttpSigner) Sign(digest [32]byte) ([]byte, error) {
	body, err := json.Marshal(signDigestRequest{
		Digest: "0x" + hex.EncodeToString(digest[:]),
	})
	if err != nil {
		return nil, remitErr(ErrCodeServerError,
			fmt.Sprintf("HttpSigner: failed to marshal sign request: %s", err),
			nil,
		)
	}

	req, err := http.NewRequest("POST", h.url+"/sign/digest", bytes.NewReader(body))
	if err != nil {
		return nil, remitErr(ErrCodeNetworkError,
			fmt.Sprintf("HttpSigner: failed to build request: %s", err),
			nil,
		)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+h.token)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, remitErr(ErrCodeNetworkError,
			fmt.Sprintf("HttpSigner: cannot reach signer server: %s", err),
			map[string]any{"url": h.url},
		)
	}
	defer resp.Body.Close()

	if resp.StatusCode == 401 {
		return nil, remitErr(ErrCodeUnauthorized,
			"HttpSigner: unauthorized -- check your REMIT_SIGNER_TOKEN",
			nil,
		)
	}
	if resp.StatusCode == 403 {
		reason := readErrorReason(resp.Body)
		return nil, remitErr("POLICY_DENIED",
			fmt.Sprintf("HttpSigner: policy denied -- %s", reason),
			map[string]any{"reason": reason},
		)
	}
	if resp.StatusCode != 200 {
		reason := readErrorReason(resp.Body)
		return nil, remitErr(ErrCodeServerError,
			fmt.Sprintf("HttpSigner: POST /sign/digest failed (%d): %s", resp.StatusCode, reason),
			map[string]any{"status": resp.StatusCode},
		)
	}

	var sigResp signDigestResponse
	if err := json.NewDecoder(resp.Body).Decode(&sigResp); err != nil {
		return nil, remitErr(ErrCodeServerError,
			fmt.Sprintf("HttpSigner: POST /sign/digest returned invalid JSON: %s", err),
			nil,
		)
	}
	if sigResp.Signature == "" {
		return nil, remitErr(ErrCodeServerError,
			"HttpSigner: server returned no signature",
			nil,
		)
	}

	sigHex := strings.TrimPrefix(sigResp.Signature, "0x")
	sigBytes, err := hex.DecodeString(sigHex)
	if err != nil {
		return nil, remitErr(ErrCodeServerError,
			fmt.Sprintf("HttpSigner: invalid signature hex: %s", err),
			nil,
		)
	}
	if len(sigBytes) != 65 {
		return nil, remitErr(ErrCodeServerError,
			fmt.Sprintf("HttpSigner: expected 65-byte signature, got %d bytes", len(sigBytes)),
			map[string]any{"length": len(sigBytes)},
		)
	}

	return sigBytes, nil
}

// Address returns the cached Ethereum address of the signing key.
func (h *HttpSigner) Address() common.Address {
	return h.address
}

// String returns a safe representation that never includes the bearer token.
func (h *HttpSigner) String() string {
	return fmt.Sprintf("HttpSigner{address: %s}", h.address.Hex())
}

// readErrorReason attempts to parse a JSON error response and extract
// the reason or error message. Falls back to reading raw body text.
func readErrorReason(body io.Reader) string {
	raw, err := io.ReadAll(io.LimitReader(body, 4096))
	if err != nil || len(raw) == 0 {
		return "unknown"
	}
	var errResp signerErrorResponse
	if json.Unmarshal(raw, &errResp) == nil {
		if errResp.Reason != "" {
			return errResp.Reason
		}
		if errResp.Error != "" {
			return errResp.Error
		}
	}
	return string(raw)
}
