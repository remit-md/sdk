defmodule RemitMd do
  @moduledoc """
  remit.md - universal payment protocol for AI agents.

  The primary entry points are `RemitMd.Wallet` (production client) and
  `RemitMd.MockRemit` (in-memory test double).

  ## Quickstart

      # 1. Testing (no keys, no network)
      {:ok, mock} = RemitMd.MockRemit.start_link()
      wallet = RemitMd.Wallet.new(mock: mock, address: "0xMyAgent")
      {:ok, tx} = RemitMd.Wallet.pay(wallet, "0xRecipient", "1.50")

      # 2. Production
      wallet = RemitMd.Wallet.from_env()
      {:ok, tx} = RemitMd.Wallet.pay(wallet, "0xRecipient", "1.50")

  ## Payment Models

  | Function                          | Model     | Use Case                              |
  |-----------------------------------|-----------|---------------------------------------|
  | `Wallet.pay/4`                    | Direct    | One-off payments                      |
  | `Wallet.create_escrow/4`          | Escrow    | Milestone-gated work                  |
  | `Wallet.open_tab/4`               | Tab       | High-frequency micro-payments         |
  | `Wallet.create_stream/4`          | Stream    | Time-based continuous payments        |
  | `Wallet.post_bounty/3`            | Bounty    | Open tasks (any agent can claim)      |

  ## Configuration

  Environment variables:

  - `REMITMD_KEY` - secp256k1 private key (required for production)
  - `REMITMD_PRIVATE_KEY` - deprecated alias for `REMITMD_KEY`
  - `REMITMD_CHAIN` - chain name, default `"base"`. Options: `"base-sepolia"`
  - `REMITMD_API_URL` - override the API base URL (useful for self-hosted instances)

  ## Installation

  Add to `mix.exs`:

      {:remitmd, "~> 0.1"}
  """
end
