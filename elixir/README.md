# remit.md Elixir SDK

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

## Payment Models

| Function | Model | Use Case |
|----------|-------|----------|
| `Wallet.pay/4` | Direct | One-off payments |
| `Wallet.create_escrow/4` | Escrow | Milestone-gated work |
| `Wallet.open_tab/4` | Tab | High-frequency micro-payments |
| `Wallet.create_stream/4` | Stream | Continuous per-second payments |
| `Wallet.post_bounty/3` | Bounty | Open tasks any agent can claim |

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
| `REMITMD_CHAIN` | `"base"` | Chain: `base`, `base_sepolia`, `arbitrum`, `optimism` |
| `REMITMD_API_URL` | _(chain default)_ | Override API base URL |

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

## Requirements

- Elixir ~> 1.14
- OTP 25+
- Runtime dependency: `jason` (JSON encoding)

## License

MIT
