package remitmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/ethereum/go-ethereum/common"
)

// A2AExtension is an AP2 capability extension declared in an agent card.
type A2AExtension struct {
	URI         string `json:"uri"`
	Description string `json:"description"`
	Required    bool   `json:"required"`
}

// A2ACapabilities lists what an agent supports.
type A2ACapabilities struct {
	Streaming              bool           `json:"streaming"`
	PushNotifications      bool           `json:"pushNotifications"`
	StateTransitionHistory bool           `json:"stateTransitionHistory"`
	Extensions             []A2AExtension `json:"extensions"`
}

// A2ASkill is a single skill declared by the agent.
type A2ASkill struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Tags        []string `json:"tags"`
}

// A2AX402 describes the x402 payment capability advertised in the agent card.
type A2AX402 struct {
	SettleEndpoint string            `json:"settleEndpoint"`
	Assets         map[string]string `json:"assets"`
	Fees           struct {
		StandardBps  int `json:"standardBps"`
		PreferredBps int `json:"preferredBps"`
		CliffUsd     int `json:"cliffUsd"`
	} `json:"fees"`
}

// AgentCard is an A2A agent card parsed from /.well-known/agent-card.json.
type AgentCard struct {
	ProtocolVersion  string          `json:"protocolVersion"`
	Name             string          `json:"name"`
	Description      string          `json:"description"`
	URL              string          `json:"url"`
	Version          string          `json:"version"`
	DocumentationURL string          `json:"documentationUrl"`
	Capabilities     A2ACapabilities `json:"capabilities"`
	Authentication   []interface{}   `json:"authentication"`
	Skills           []A2ASkill      `json:"skills"`
	X402             A2AX402         `json:"x402"`
}

// DiscoverAgent fetches and parses the A2A agent card from
// baseURL/.well-known/agent-card.json.
//
//	card, err := remitmd.DiscoverAgent(ctx, "https://remit.md")
func DiscoverAgent(ctx context.Context, baseURL string) (*AgentCard, error) {
	url := strings.TrimRight(baseURL, "/") + "/.well-known/agent-card.json"

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("discover agent: build request: %w", err)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("discover agent: request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("discover agent: server returned %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("discover agent: read body: %w", err)
	}

	var card AgentCard
	if err := json.Unmarshal(body, &card); err != nil {
		return nil, fmt.Errorf("discover agent: parse: %w", err)
	}
	return &card, nil
}

// ─── A2A task types ───────────────────────────────────────────────────────────

// A2ATaskStatus is the status of an A2A task.
type A2ATaskStatus struct {
	State   string              `json:"state"` // "completed", "failed", "canceled", "working"
	Message *A2ATaskStatusMessage `json:"message,omitempty"`
}

// A2ATaskStatusMessage is the optional message within a task status.
type A2ATaskStatusMessage struct {
	Text string `json:"text,omitempty"`
}

// A2AArtifactPart is a single part of an A2A artifact.
type A2AArtifactPart struct {
	Kind string         `json:"kind"`
	Data map[string]any `json:"data,omitempty"`
}

// A2AArtifact is an artifact produced by an A2A task.
type A2AArtifact struct {
	Name  string            `json:"name,omitempty"`
	Parts []A2AArtifactPart `json:"parts"`
}

// A2ATask is a task in the A2A protocol.
type A2ATask struct {
	ID        string        `json:"id"`
	Status    A2ATaskStatus `json:"status"`
	Artifacts []A2AArtifact `json:"artifacts"`
}

// GetTaskTxHash extracts a txHash from the task's artifacts, if present.
func GetTaskTxHash(task *A2ATask) string {
	for _, artifact := range task.Artifacts {
		for _, part := range artifact.Parts {
			if tx, ok := part.Data["txHash"]; ok {
				if s, ok := tx.(string); ok {
					return s
				}
			}
		}
	}
	return ""
}

// ─── IntentMandate ────────────────────────────────────────────────────────────

// IntentMandate represents an intent mandate for authorized payments.
type IntentMandate struct {
	MandateID string `json:"mandateId"`
	ExpiresAt string `json:"expiresAt"`
	Issuer    string `json:"issuer"`
	Allowance struct {
		MaxAmount string `json:"maxAmount"`
		Currency  string `json:"currency"`
	} `json:"allowance"`
}

// ─── A2A client ───────────────────────────────────────────────────────────────

// A2AClientOptions configures an A2AClient.
type A2AClientOptions struct {
	// Endpoint is the full A2A endpoint URL from the agent card (e.g. "https://remit.md/a2a").
	Endpoint          string
	Signer            Signer
	ChainID           int
	VerifyingContract string
}

// SendOptions configures a Send call.
type SendOptions struct {
	To       string
	Amount   float64
	Memo     string
	Mandate  *IntentMandate
}

// A2AClient is a JSON-RPC client for sending payments via the A2A protocol.
type A2AClient struct {
	http *httpClient
	path string
}

// NewA2AClient creates an A2AClient from options.
func NewA2AClient(opts A2AClientOptions) (*A2AClient, error) {
	parsed, err := url.Parse(opts.Endpoint)
	if err != nil {
		return nil, fmt.Errorf("a2a: parse endpoint: %w", err)
	}
	baseURL := parsed.Scheme + "://" + parsed.Host
	path := parsed.Path
	if path == "" {
		path = "/a2a"
	}

	contractAddr := common.HexToAddress(opts.VerifyingContract)

	return &A2AClient{
		http: newHTTPClient(baseURL, ChainID(opts.ChainID), contractAddr, opts.Signer),
		path: path,
	}, nil
}

// A2AClientFromCard creates an A2AClient from an AgentCard and a signer.
func A2AClientFromCard(card *AgentCard, signer Signer, chain ...string) (*A2AClient, error) {
	ch := "base"
	if len(chain) > 0 && chain[0] != "" {
		ch = chain[0]
	}
	chainID := ChainBase
	if ch == "base-sepolia" {
		chainID = ChainBaseSep
	} else if ch == "localhost" {
		chainID = ChainLocalhost
	}
	return NewA2AClient(A2AClientOptions{
		Endpoint: card.URL,
		Signer:   signer,
		ChainID:  int(chainID),
	})
}

// Send sends a direct USDC payment via JSON-RPC "message/send".
func (c *A2AClient) Send(ctx context.Context, opts SendOptions) (*A2ATask, error) {
	nonce := randomHex(16)
	messageID := randomHex(16)

	message := map[string]any{
		"messageId": messageID,
		"role":      "user",
		"parts": []map[string]any{
			{
				"kind": "data",
				"data": map[string]any{
					"model":  "direct",
					"to":     opts.To,
					"amount": fmt.Sprintf("%.2f", opts.Amount),
					"memo":   opts.Memo,
					"nonce":  nonce,
				},
			},
		},
	}

	if opts.Mandate != nil {
		message["metadata"] = map[string]any{"mandate": opts.Mandate}
	}

	return c.rpc(ctx, "message/send", map[string]any{"message": message}, messageID)
}

// GetTask fetches the current state of an A2A task by ID.
func (c *A2AClient) GetTask(ctx context.Context, taskID string) (*A2ATask, error) {
	callID := taskID
	if len(callID) > 16 {
		callID = callID[:16]
	}
	return c.rpc(ctx, "tasks/get", map[string]any{"id": taskID}, callID)
}

// CancelTask cancels an in-progress A2A task.
func (c *A2AClient) CancelTask(ctx context.Context, taskID string) (*A2ATask, error) {
	callID := taskID
	if len(callID) > 16 {
		callID = callID[:16]
	}
	return c.rpc(ctx, "tasks/cancel", map[string]any{"id": taskID}, callID)
}

func (c *A2AClient) rpc(ctx context.Context, method string, params any, callID string) (*A2ATask, error) {
	rpcBody := map[string]any{
		"jsonrpc": "2.0",
		"id":      callID,
		"method":  method,
		"params":  params,
	}

	bodyBytes, err := json.Marshal(rpcBody)
	if err != nil {
		return nil, fmt.Errorf("a2a: marshal: %w", err)
	}

	reqURL := c.http.baseURL + c.path
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, reqURL, bytes.NewReader(bodyBytes))
	if err != nil {
		return nil, fmt.Errorf("a2a: create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	if err := c.http.sign(req, bodyBytes); err != nil {
		return nil, fmt.Errorf("a2a: sign: %w", err)
	}

	resp, err := c.http.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("a2a: request: %w", err)
	}
	defer resp.Body.Close()

	respBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("a2a: read response: %w", err)
	}

	var rpcResp struct {
		Result *A2ATask `json:"result"`
		Error  *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(respBytes, &rpcResp); err != nil {
		return nil, fmt.Errorf("a2a: parse response: %w", err)
	}

	if rpcResp.Error != nil {
		return nil, fmt.Errorf("a2a error: %s", rpcResp.Error.Message)
	}

	if rpcResp.Result != nil {
		return rpcResp.Result, nil
	}

	// Fallback: try parsing entire response as task
	var task A2ATask
	if err := json.Unmarshal(respBytes, &task); err != nil {
		return nil, fmt.Errorf("a2a: unexpected response format")
	}
	return &task, nil
}
