# remit.md Elixir SDK

[![CI](https://github.com/remit-md/sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/remit-md/sdk/actions/workflows/ci.yml)

Universal payment protocol for AI agents — Elixir client.

## Installation

```elixir
# mix.exs
{:remitmd, "~> 0.1"}
```

## Quickstart

```elixir
# Testing — no keys, no network
{:ok, mock} = RemitMd.MockRemit.start_link()
RemitMd.MockRemit.set_balance(mock, "0xYourAgent", "500.00")

wallet = RemitMd.Wallet.new(mock: mock, address: "0xYourAgent")
{:ok, tx} = RemitMd.Wallet.pay(wallet, "0xRecipient", "1.50")
IO.puts("Sent! status: #{tx.status}")
```

```elixir
# Production — set REMITMD_PRIVATE_KEY environment variable
wallet = RemitMd.Wallet.from_env()
{:ok, tx} = RemitMd.Wallet.pay(wallet, "0xRecipient", "1.50")
IO.puts("tx_hash: #{tx.tx_hash}")
```

## Permits (Gasless USDC Approval)

All payment methods auto-sign EIP-2612 permits when no explicit permit is provided.
The wallet fetches the on-chain nonce, signs the permit, and includes it in the request automatically.

```elixir
# Auto-permit (recommended) — just call the method, permit is handled internally
{:ok, tx} = RemitMd.Wallet.pay(wallet, "0xRecipient", "5.00")

# Manual permit — sign yourself if you need control over deadline/nonce
{:ok, contracts} = RemitMd.Wallet.get_contracts(wallet)
permit = RemitMd.Wallet.sign_permit(wallet, contracts.router, "5.00")
{:ok, tx} = RemitMd.Wallet.pay(wallet, "0xRecipient", "5.00", permit: permit)

# Low-level permit — full control over all parameters
permit = RemitMd.Wallet.sign_usdc_permit(wallet, contracts.router,
  5_000_000,          # base units (6 decimals)
  :os.system_time(:second) + 3600,  # deadline
  nonce: 0
)
```

Auto-permit works on: `pay`, `create_escrow`, `create_tab`, `create_stream`, `create_bounty`, `place_deposit`.

## Payment Models

| Function | Model | Use Case |
|----------|-------|----------|
| `Wallet.pay/4` | Direct | One-off payments |
| `Wallet.create_escrow/4` | Escrow | Milestone-gated work |
| `Wallet.open_tab/4` | Tab | High-frequency micro-payments |
| `Wallet.create_stream/4` | Stream | Continuous per-second payments |
| `Wallet.post_bounty/3` | Bounty | Open tasks any agent can claim |
| `Wallet.place_deposit/4` | Deposit | Refundable collateral |

## Testing with MockRemit

`MockRemit` is an OTP `GenServer` that implements the full payment API
in-memory. Tests complete in microseconds — no network, no blockchain.

```elixir
defmodule MyAgentTest do
  use ExUnit.Case

  test "agent pays for inference" do
    {:ok, mock} = RemitMd.MockRemit.start_link()
    RemitMd.MockRemit.set_balance(mock, "0xAgent", "100.00")

    wallet = RemitMd.Wallet.new(mock: mock, address: "0xAgent")
    {:ok, _tx} = RemitMd.Wallet.pay(wallet, "0xProvider", "0.003")

    assert RemitMd.MockRemit.was_paid?(mock, "0xProvider")
    assert RemitMd.MockRemit.total_paid_to(mock, "0xProvider") == "0.003"
  end
end
```

## Escrow Example

```elixir
wallet = RemitMd.Wallet.from_env()

# Create escrow
{:ok, esc} = RemitMd.Wallet.create_escrow(wallet, "0xContractor", "200.00",
  milestones: ["design_approved", "implementation_done", "tests_passing"],
  description: "Build data pipeline"
)

# Release milestones as work completes
{:ok, esc} = RemitMd.Wallet.pay_milestone(wallet, esc.escrow_id, "design_approved")
{:ok, esc} = RemitMd.Wallet.pay_milestone(wallet, esc.escrow_id, "implementation_done")
{:ok, esc} = RemitMd.Wallet.pay_milestone(wallet, esc.escrow_id, "tests_passing")
# esc.status == "complete"
```

## Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `REMITMD_PRIVATE_KEY` | — | secp256k1 private key (required for production) |
| `REMITMD_CHAIN` | `"base"` | Chain: `base`, `base_sepolia` |
| `REMITMD_API_URL` | _(chain default)_ | Override API base URL |
| `REMITMD_RPC_URL` | _(chain default)_ | JSON-RPC URL for on-chain reads (nonce fetching) |

## Custom Signer

Implement `RemitMd.Signer` to use HSM, KMS, or hardware wallets:

```elixir
defmodule MyKmsSigner do
  @behaviour RemitMd.Signer

  @impl true
  def sign(_signer, message), do: MyKms.sign(message)

  @impl true
  def address(_signer), do: "0xYourAgentAddress"
end

wallet = RemitMd.Wallet.new(signer: MyKmsSigner, chain: "base")
```

## Additional Methods

```elixir
# Contract discovery (cached per session)
{:ok, contracts} = RemitMd.Wallet.get_contracts(wallet)

# Tab provider (signing charges)
sig = RemitMd.Wallet.sign_tab_charge(wallet, tab_contract, tab_id, total_charged, call_count)
{:ok, charge} = RemitMd.Wallet.charge_tab(wallet, tab_id, amount, cumulative, call_count, provider_sig)
{:ok, tab} = RemitMd.Wallet.close_tab(wallet, tab_id)

# Webhooks
{:ok, wh} = RemitMd.Wallet.register_webhook(wallet, "https://...", ["payment.received"])

# Operator links
{:ok, link} = RemitMd.Wallet.create_fund_link(wallet)
{:ok, link} = RemitMd.Wallet.create_withdraw_link(wallet)

# Testnet funding
{:ok, result} = RemitMd.Wallet.mint(wallet, 100)  # $100 testnet USDC
```

## Error Handling

Errors return `{:error, %RemitMd.Error{}}` with machine-readable codes and actionable details:

```elixir
case RemitMd.Wallet.pay(wallet, "0xRecipient", "100.00") do
  {:ok, tx} -> IO.puts("Paid: #{tx.tx_hash}")
  {:error, %{code: "INSUFFICIENT_BALANCE"} = err} ->
    IO.puts("Need more USDC: #{err.message}")
    # Enriched: "Insufficient USDC balance: have $5.00, need $100.00"
  {:error, err} -> IO.puts("Error [#{err.code}]: #{err.message}")
end
```

## Requirements

- Elixir ~> 1.14
- OTP 25+
- Runtime dependency: `jason` (JSON encoding)

## License

MIT
