#!/usr/bin/env elixir
# remit.md Elixir SDK - Quickstart
# Run: mix run examples/quickstart.exs

alias RemitMd.{MockRemit, Wallet}

IO.puts("=== remit.md Elixir SDK Quickstart ===\n")

# All examples use MockRemit - no keys, no network required.
{:ok, mock} = MockRemit.start_link()
MockRemit.set_balance(mock, "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "1000.00")

payer = Wallet.new(mock: mock, address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
payee = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# ── 1. Direct pay ────────────────────────────────────────────────────────────
IO.puts("1. Direct Pay")
{:ok, tx} = Wallet.pay(payer, payee, "5.00", description: "API call fee")
IO.puts("   tx_id:  #{tx.tx_id}")
IO.puts("   status: #{tx.status}")
IO.puts("   hash:   #{tx.tx_hash}\n")

# ── 2. Balance ───────────────────────────────────────────────────────────────
IO.puts("2. Balance")
{:ok, bal} = Wallet.balance(payer)
IO.puts("   address: #{bal.address}")
IO.puts("   usdc:    #{bal.usdc}\n")

# ── 3. Escrow (milestone-based) ──────────────────────────────────────────────
IO.puts("3. Escrow")
{:ok, esc} = Wallet.create_escrow(payer, payee, "100.00",
  milestones: ["design_approved", "code_reviewed", "deployed"],
  description: "Website redesign project"
)
IO.puts("   escrow_id: #{esc.escrow_id}")
IO.puts("   status:    #{esc.status}")
IO.puts("   milestones: #{length(esc.milestones)}\n")

# Release first milestone
{:ok, esc} = Wallet.pay_milestone(payer, esc.escrow_id, "design_approved")
IO.puts("   After releasing 'design_approved': #{esc.status}\n")

# ── 4. Reputation ────────────────────────────────────────────────────────────
IO.puts("4. Reputation")
{:ok, rep} = Wallet.reputation(payer, payee)
IO.puts("   wallet:     #{rep.wallet}")
IO.puts("   avg_rating: #{rep.avg_rating}/100\n")

# ── 5. Spending analytics ────────────────────────────────────────────────────
IO.puts("5. Spending Summary")
Wallet.pay(payer, payee, "2.50")
{:ok, summary} = Wallet.spending(payer)
IO.puts("   total_spent:       #{summary.total_spent_usdc} USDC")
IO.puts("   transaction_count: #{summary.transaction_count}\n")

# ── 6. Assertions ────────────────────────────────────────────────────────────
IO.puts("6. MockRemit Assertions")
IO.puts("   was_paid?(payee):        #{MockRemit.was_paid?(mock, payee)}")
IO.puts("   total_paid_to(payee):    #{MockRemit.total_paid_to(mock, payee)} USDC")
IO.puts("   transaction_count:       #{MockRemit.transaction_count(mock)}")

MockRemit.reset(mock)
IO.puts("   After reset - count:     #{MockRemit.transaction_count(mock)}\n")

IO.puts("All examples completed successfully!")
