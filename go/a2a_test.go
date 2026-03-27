package remitmd_test

import (
	"testing"

	remitmd "github.com/remit-md/sdk/go"
)

// Test key - well-known Hardhat/Foundry test key #0 (not a real wallet).
const testKey = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

func TestNewA2AClient_ValidEndpoint(t *testing.T) {
	signer, err := remitmd.NewPrivateKeySigner(testKey)
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	client, err := remitmd.NewA2AClient(remitmd.A2AClientOptions{
		Endpoint: "https://remit.md/a2a",
		Signer:   signer,
		ChainID:  8453,
	})
	if err != nil {
		t.Fatalf("NewA2AClient failed: %v", err)
	}
	if client == nil {
		t.Fatal("expected non-nil client")
	}
}

func TestNewA2AClient_InvalidEndpoint(t *testing.T) {
	signer, _ := remitmd.NewPrivateKeySigner(testKey)
	_, err := remitmd.NewA2AClient(remitmd.A2AClientOptions{
		Endpoint: "://invalid",
		Signer:   signer,
		ChainID:  8453,
	})
	if err == nil {
		t.Fatal("expected error for invalid endpoint")
	}
}

func TestA2AClientFromCard_DefaultChain(t *testing.T) {
	signer, _ := remitmd.NewPrivateKeySigner(testKey)
	card := &remitmd.AgentCard{
		URL: "https://remit.md/a2a",
	}
	client, err := remitmd.A2AClientFromCard(card, signer)
	if err != nil {
		t.Fatalf("A2AClientFromCard failed: %v", err)
	}
	if client == nil {
		t.Fatal("expected non-nil client")
	}
}

func TestA2AClientFromCard_BaseSepolia(t *testing.T) {
	signer, _ := remitmd.NewPrivateKeySigner(testKey)
	card := &remitmd.AgentCard{
		URL: "https://testnet.remit.md/a2a",
	}
	client, err := remitmd.A2AClientFromCard(card, signer, "base-sepolia")
	if err != nil {
		t.Fatalf("A2AClientFromCard failed: %v", err)
	}
	if client == nil {
		t.Fatal("expected non-nil client")
	}
}

func TestA2AClientFromCard_Localhost(t *testing.T) {
	signer, _ := remitmd.NewPrivateKeySigner(testKey)
	card := &remitmd.AgentCard{URL: "http://localhost:3000/a2a"}
	client, err := remitmd.A2AClientFromCard(card, signer, "localhost")
	if err != nil {
		t.Fatalf("A2AClientFromCard failed: %v", err)
	}
	if client == nil {
		t.Fatal("expected non-nil client")
	}
}

func TestGetTaskTxHash_Found(t *testing.T) {
	task := &remitmd.A2ATask{
		ID: "test-task-1",
		Status: remitmd.A2ATaskStatus{
			State: "completed",
		},
		Artifacts: []remitmd.A2AArtifact{
			{
				Name: "result",
				Parts: []remitmd.A2AArtifactPart{
					{
						Kind: "data",
						Data: map[string]any{
							"txHash": "0xabc123",
						},
					},
				},
			},
		},
	}
	hash := remitmd.GetTaskTxHash(task)
	if hash != "0xabc123" {
		t.Errorf("expected 0xabc123, got %s", hash)
	}
}

func TestGetTaskTxHash_NotFound(t *testing.T) {
	task := &remitmd.A2ATask{
		ID: "test-task-2",
		Status: remitmd.A2ATaskStatus{
			State: "completed",
		},
		Artifacts: []remitmd.A2AArtifact{
			{
				Name: "result",
				Parts: []remitmd.A2AArtifactPart{
					{Kind: "data", Data: map[string]any{"other": "value"}},
				},
			},
		},
	}
	hash := remitmd.GetTaskTxHash(task)
	if hash != "" {
		t.Errorf("expected empty string, got %s", hash)
	}
}

func TestGetTaskTxHash_EmptyArtifacts(t *testing.T) {
	task := &remitmd.A2ATask{
		ID:        "test-task-3",
		Artifacts: nil,
	}
	hash := remitmd.GetTaskTxHash(task)
	if hash != "" {
		t.Errorf("expected empty string for nil artifacts, got %s", hash)
	}
}

func TestA2ATypes_Construction(t *testing.T) {
	ext := remitmd.A2AExtension{
		URI:         "https://remit.md/x402",
		Description: "x402 payments",
		Required:    true,
	}
	if ext.URI != "https://remit.md/x402" {
		t.Errorf("expected URI, got %s", ext.URI)
	}

	cap := remitmd.A2ACapabilities{Streaming: true}
	if !cap.Streaming {
		t.Error("expected streaming true")
	}

	skill := remitmd.A2ASkill{ID: "pay", Name: "Pay", Tags: []string{"payment"}}
	if skill.ID != "pay" {
		t.Errorf("expected ID pay, got %s", skill.ID)
	}
}

func TestIntentMandate_Fields(t *testing.T) {
	mandate := remitmd.IntentMandate{
		MandateID: "m-123",
		ExpiresAt: "2026-12-31T23:59:59Z",
		Issuer:    "0xabc",
	}
	if mandate.MandateID != "m-123" {
		t.Errorf("expected m-123, got %s", mandate.MandateID)
	}
}

func TestSendOptions_Fields(t *testing.T) {
	opts := remitmd.SendOptions{
		To:     "0xrecipient",
		Amount: 1.50,
		Memo:   "test",
	}
	if opts.To != "0xrecipient" {
		t.Errorf("expected 0xrecipient, got %s", opts.To)
	}
	if opts.Amount != 1.50 {
		t.Errorf("expected 1.50, got %f", opts.Amount)
	}
}
