#!/usr/bin/env ruby
# frozen_string_literal: true

#
# remit.md Ruby SDK — Quickstart
#
# All examples use MockRemit, so no API key or network connection is needed.
# To use a real wallet, replace MockRemit.new / mock.wallet with:
#
#   wallet = Remitmd::RemitWallet.new(private_key: ENV["REMITMD_PRIVATE_KEY"])
#

require_relative "../lib/remitmd"

RECIPIENT  = "0x0000000000000000000000000000000000000001"
PAYEE      = "0x0000000000000000000000000000000000000002"
CHALLENGER = "0x0000000000000000000000000000000000000003"

mock   = Remitmd::MockRemit.new
wallet = mock.wallet

puts "=== remit.md Ruby SDK Quickstart ===\n\n"

# 1. Direct payment
puts "1. Direct Payment"
tx = wallet.pay(RECIPIENT, 1.50, memo: "AI inference fee")
puts "   Sent: #{tx.amount} USDC → #{tx.to}"
puts "   Balance after: #{mock.balance} USDC\n\n"

mock.reset

# 2. Escrow
puts "2. Escrow Payment"
escrow = wallet.create_escrow(PAYEE, 50.00, memo: "Code review task")
puts "   Escrow created: #{escrow.id} (#{escrow.status})"
release_tx = wallet.release_escrow(escrow.id)
puts "   Released: #{release_tx.amount} USDC → #{release_tx.to}\n\n"

mock.reset

# 3. Metered Tab
puts "3. Metered Tab (Off-chain billing)"
tab = wallet.create_tab(PAYEE, 10.00)
puts "   Tab opened: #{tab.id} (limit: #{tab.limit} USDC)"
wallet.debit_tab(tab.id, 0.003, "Request #1")
wallet.debit_tab(tab.id, 0.003, "Request #2")
wallet.debit_tab(tab.id, 0.003, "Request #3")
settle_tx = wallet.settle_tab(tab.id)
puts "   Settled: #{settle_tx.amount} USDC on-chain\n\n"

mock.reset

# 4. Payment Stream
puts "4. Payment Stream (Real-time)"
stream = wallet.create_stream(RECIPIENT, 0.001, 10.00)
puts "   Stream started: #{stream.id} at #{stream.rate_per_sec} USDC/sec"
puts "   Deposited: #{stream.deposited} USDC\n\n"

mock.reset

# 5. Bounty
puts "5. Bounty"
bounty = wallet.create_bounty(25.00, "Summarise the top 10 Ethereum EIPs of 2025")
puts "   Bounty posted: #{bounty.id} (#{bounty.award} USDC)"
win_tx = wallet.award_bounty(bounty.id, CHALLENGER)
puts "   Awarded to: #{win_tx.to}\n\n"

mock.reset

# 6. Security Deposit
puts "6. Security Deposit"
dep = wallet.lock_deposit(PAYEE, 100.00, 86_400)
puts "   Deposit locked: #{dep.id} (#{dep.amount} USDC, beneficiary: #{dep.beneficiary})\n\n"

mock.reset

# 7. Reputation check
puts "7. Reputation"
rep = wallet.reputation(RECIPIENT)
puts "   Address: #{rep.address}"
puts "   Score: #{rep.score} | Disputes: #{rep.dispute_rate}\n\n"

puts "All payment models demonstrated successfully."
