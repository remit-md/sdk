// Package langchain provides remit.md tool adapters for Go agent frameworks.
// Currently targets langgraph-go and the generic tool interface pattern
// common across Go LLM libraries.
//
// # Usage with a generic tool interface
//
//	wallet, _ := remitmd.FromEnv()
//	tools := langchain.NewTools(wallet)
//	// Register tools with your agent framework's tool registry
//	for _, tool := range tools {
//	    agent.RegisterTool(tool)
//	}
package langchain

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/remit-md/sdk/go"
	"github.com/shopspring/decimal"
)

// Tool is the generic interface implemented by all remit.md LangChain tools.
// This matches the interface expected by most Go LLM agent frameworks.
type Tool interface {
	Name() string
	Description() string
	Schema() map[string]any
	Call(ctx context.Context, input string) (string, error)
}

// NewTools returns all remit.md payment tools for an agent framework.
// Pass these to your framework's tool registry.
func NewTools(wallet *remitmd.Wallet) []Tool {
	return []Tool{
		&PayTool{wallet: wallet},
		&BalanceTool{wallet: wallet},
		&CreateEscrowTool{wallet: wallet},
		&CheckEscrowTool{wallet: wallet},
	}
}

// ─── PayTool ──────────────────────────────────────────────────────────────────

// PayTool sends a direct USDC payment to an address.
type PayTool struct {
	wallet *remitmd.Wallet
}

func (t *PayTool) Name() string { return "remitmd_pay" }

func (t *PayTool) Description() string {
	return "Send a USDC payment to another agent or Ethereum address. " +
		"Use this to pay for completed work, services, or to transfer value to another agent. " +
		"Requires recipient address (0x-prefixed Ethereum address) and amount in USDC."
}

func (t *PayTool) Schema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"recipient": map[string]any{
				"type":        "string",
				"description": "Ethereum address of the payment recipient (0x-prefixed, 42 characters)",
				"pattern":     "^0x[0-9a-fA-F]{40}$",
			},
			"amount_usdc": map[string]any{
				"type":        "number",
				"description": "Amount to pay in USDC (e.g., 1.50 means 1.50 USDC)",
				"minimum":     0.000001,
			},
			"memo": map[string]any{
				"type":        "string",
				"description": "Optional note describing what the payment is for",
			},
		},
		"required": []string{"recipient", "amount_usdc"},
	}
}

type payInput struct {
	Recipient  string  `json:"recipient"`
	AmountUSDC float64 `json:"amount_usdc"`
	Memo       string  `json:"memo,omitempty"`
}

func (t *PayTool) Call(ctx context.Context, input string) (string, error) {
	var in payInput
	if err := json.Unmarshal([]byte(input), &in); err != nil {
		return "", fmt.Errorf("invalid input: %w", err)
	}
	amount := decimal.NewFromFloat(in.AmountUSDC)
	var opts []remitmd.PayOption
	if in.Memo != "" {
		opts = append(opts, remitmd.WithMemo(in.Memo))
	}
	tx, err := t.wallet.Pay(ctx, in.Recipient, amount, opts...)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("Payment sent: %s USDC to %s (tx: %s)", amount.String(), in.Recipient, tx.ID), nil
}

// ─── BalanceTool ──────────────────────────────────────────────────────────────

// BalanceTool checks the wallet's current USDC balance.
type BalanceTool struct {
	wallet *remitmd.Wallet
}

func (t *BalanceTool) Name() string { return "remitmd_balance" }

func (t *BalanceTool) Description() string {
	return "Check the current USDC balance of this agent's wallet. " +
		"Call this before making payments to verify sufficient funds."
}

func (t *BalanceTool) Schema() map[string]any {
	return map[string]any{
		"type":       "object",
		"properties": map[string]any{},
	}
}

func (t *BalanceTool) Call(ctx context.Context, _ string) (string, error) {
	bal, err := t.wallet.Balance(ctx)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("Current balance: %s USDC (address: %s)", bal.USDC.String(), bal.Address), nil
}

// ─── CreateEscrowTool ─────────────────────────────────────────────────────────

// CreateEscrowTool creates a locked escrow for work yet to be completed.
type CreateEscrowTool struct {
	wallet *remitmd.Wallet
}

func (t *CreateEscrowTool) Name() string { return "remitmd_create_escrow" }

func (t *CreateEscrowTool) Description() string {
	return "Create a USDC escrow payment that locks funds until you verify work is complete. " +
		"Use this when hiring another agent for a task - the funds are held securely until you " +
		"call remitmd_release_escrow. If the work is unsatisfactory, call remitmd_cancel_escrow " +
		"to recover your funds."
}

func (t *CreateEscrowTool) Schema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"payee": map[string]any{
				"type":        "string",
				"description": "Ethereum address of the agent doing the work",
				"pattern":     "^0x[0-9a-fA-F]{40}$",
			},
			"amount_usdc": map[string]any{
				"type":        "number",
				"description": "Total payment in USDC for completing the task",
				"minimum":     0.01,
			},
			"description": map[string]any{
				"type":        "string",
				"description": "Description of the work to be done",
			},
		},
		"required": []string{"payee", "amount_usdc", "description"},
	}
}

type createEscrowInput struct {
	Payee       string  `json:"payee"`
	AmountUSDC  float64 `json:"amount_usdc"`
	Description string  `json:"description"`
}

func (t *CreateEscrowTool) Call(ctx context.Context, input string) (string, error) {
	var in createEscrowInput
	if err := json.Unmarshal([]byte(input), &in); err != nil {
		return "", fmt.Errorf("invalid input: %w", err)
	}
	amount := decimal.NewFromFloat(in.AmountUSDC)
	escrow, err := t.wallet.CreateEscrow(ctx, in.Payee, amount,
		remitmd.WithEscrowMemo(in.Description),
	)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf(
		"Escrow created: %s USDC locked for %s (escrow_id: %s). "+
			"Call remitmd_release_escrow with escrow_id=%s when work is verified complete.",
		amount.String(), in.Payee, escrow.InvoiceID, escrow.InvoiceID,
	), nil
}

// ─── CheckEscrowTool ──────────────────────────────────────────────────────────

// CheckEscrowTool retrieves the current state of an escrow.
type CheckEscrowTool struct {
	wallet *remitmd.Wallet
}

func (t *CheckEscrowTool) Name() string { return "remitmd_check_escrow" }

func (t *CheckEscrowTool) Description() string {
	return "Check the status of an existing escrow payment. " +
		"Returns the current status (funded/released/cancelled), amount, and parties."
}

func (t *CheckEscrowTool) Schema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"escrow_id": map[string]any{
				"type":        "string",
				"description": "The escrow ID returned when the escrow was created",
			},
		},
		"required": []string{"escrow_id"},
	}
}

type checkEscrowInput struct {
	EscrowID string `json:"escrow_id"`
}

func (t *CheckEscrowTool) Call(ctx context.Context, input string) (string, error) {
	var in checkEscrowInput
	if err := json.Unmarshal([]byte(input), &in); err != nil {
		return "", fmt.Errorf("invalid input: %w", err)
	}
	escrow, err := t.wallet.GetEscrow(ctx, in.EscrowID)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf(
		"Escrow %s: status=%s, amount=%s USDC, payer=%s, payee=%s",
		escrow.InvoiceID, escrow.Status, escrow.Amount.String(), escrow.Payer, escrow.Payee,
	), nil
}
