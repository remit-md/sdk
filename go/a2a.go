package remitmd

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
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
