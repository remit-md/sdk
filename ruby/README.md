# remit.md Ruby SDK

Universal payment protocol for AI agents — Ruby client library.

[![CI](https://github.com/remit-md/sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/remit-md/sdk/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/remitmd.svg)](https://badge.fury.io/rb/remitmd)

## Installation

```ruby
gem "remitmd"
```

or install directly:

```bash
gem install remitmd
```

## Quickstart

```ruby
require "remitmd"

wallet = Remitmd::RemitWallet.new(private_key: ENV["REMITMD_PRIVATE_KEY"])

# Direct payment
tx = wallet.pay("0xRecipient0000000000000000000000000000001", 1.50)
puts tx.tx_hash

# Check reputation
rep = wallet.reputation("0xSomeAgent000000000000000000000000001")
puts "Score: #{rep.score}"
```

Or from environment variables:

```ruby
wallet = Remitmd::RemitWallet.from_env
# Requires: REMITMD_PRIVATE_KEY
# Optional: REMITMD_CHAIN (default: "base"), REMITMD_API_URL
```

## Payment Models

### Direct Payment

```ruby
tx = wallet.pay("0xRecipient...", 5.00, memo: "AI inference fee")
```

### Escrow

```ruby
escrow = wallet.create_escrow("0xContractor...", 100.00, memo: "Code review")
# Work happens...
tx = wallet.release_escrow(escrow.id)   # pay the contractor
# or
tx = wallet.cancel_escrow(escrow.id)    # refund yourself
```

### Metered Tab (off-chain billing)

```ruby
tab = wallet.create_tab("0xProvider...", 50.00)  # $50 credit limit

# Hundreds of off-chain debits — zero gas, instant
wallet.debit_tab(tab.id, 0.003, "API call #1")
wallet.debit_tab(tab.id, 0.003, "API call #2")

# One on-chain settlement when done
tx = wallet.settle_tab(tab.id)
```

### Payment Stream

```ruby
stream = wallet.create_stream("0xWorker...", 0.001, 100.00)
# Worker receives 0.001 USDC/second, funded with 100 USDC deposit

tx = wallet.withdraw_stream(stream.id)
```

### Bounty

```ruby
bounty = wallet.create_bounty(25.00, "Summarise top 10 EIPs of 2025")

# Any agent can submit work; you decide the winner
tx = wallet.award_bounty(bounty.id, "0xWinner...")
```

### Security Deposit

```ruby
# Lock funds; beneficiary can claim if conditions are violated
dep = wallet.lock_deposit("0xCounterpart...", 100.00, 86_400)  # 24h lock
```

### Payment Intent

```ruby
# Propose payment terms before committing
intent = wallet.propose_intent("0xCounterpart...", 50.00, type: "escrow")
```

## Testing with MockRemit

MockRemit gives you a zero-network, zero-latency test double. No API key needed.

```ruby
require "remitmd"

RSpec.describe MyPayingAgent do
  let(:mock)   { Remitmd::MockRemit.new }
  let(:wallet) { mock.wallet }

  after { mock.reset }

  it "pays the correct amount" do
    agent = MyPayingAgent.new(wallet: wallet)
    agent.run(task: "summarise document")

    expect(mock.was_paid?("0xProvider...", 0.003)).to be true
    expect(mock.balance).to eq(BigDecimal("9999.997"))
  end
end
```

### MockRemit assertions

```ruby
mock.was_paid?(address, amount)   # true/false
mock.total_paid_to(address)       # BigDecimal — sum of all payments to address
mock.transaction_count            # Integer
mock.balance                      # BigDecimal — current balance
mock.transactions                 # Array<Transaction>
mock.set_balance(amount)          # Override starting balance
mock.reset                        # Clear all state
```

## All Methods

```ruby
# Balance & analytics
wallet.balance                          # Balance
wallet.history(limit: 50, offset: 0)   # TransactionList
wallet.reputation(address)             # Reputation
wallet.spending_summary                 # SpendingSummary
wallet.remaining_budget                 # Budget

# Direct payment
wallet.pay(to, amount, memo: nil)       # Transaction

# Escrow
wallet.create_escrow(payee, amount, memo: nil, expires_in_secs: nil)  # Escrow
wallet.release_escrow(escrow_id, memo: nil)                            # Transaction
wallet.cancel_escrow(escrow_id)                                        # Transaction
wallet.get_escrow(escrow_id)                                           # Escrow

# Tabs
wallet.create_tab(counterpart, limit, closes_in_secs: nil)  # Tab
wallet.debit_tab(tab_id, amount, memo = "")                  # TabDebit
wallet.settle_tab(tab_id)                                    # Transaction

# Streams
wallet.create_stream(recipient, rate_per_sec, deposit)  # Stream
wallet.withdraw_stream(stream_id)                        # Transaction

# Bounties
wallet.create_bounty(award, description, expires_in_secs: nil)  # Bounty
wallet.award_bounty(bounty_id, winner)                           # Transaction

# Deposits
wallet.lock_deposit(beneficiary, amount, lock_secs)  # Deposit

# Intents
wallet.propose_intent(to, amount, type: "direct")  # Intent
```

## Error Handling

All errors are `Remitmd::RemitError` with structured fields:

```ruby
begin
  wallet.pay("invalid", 1.00)
rescue Remitmd::RemitError => e
  puts e.code     # "INVALID_ADDRESS"
  puts e.message  # "[INVALID_ADDRESS] expected 0x-prefixed ... — https://remit.md/..."
  puts e.doc_url  # Direct link to error documentation
  puts e.context  # Hash with the bad value
end
```

Error codes: `INVALID_ADDRESS`, `INVALID_AMOUNT`, `INSUFFICIENT_FUNDS`, `ESCROW_NOT_FOUND`,
`TAB_NOT_FOUND`, `STREAM_NOT_FOUND`, `BOUNTY_NOT_FOUND`, `DEPOSIT_NOT_FOUND`, `UNAUTHORIZED`,
`RATE_LIMITED`, `NETWORK_ERROR`, `SERVER_ERROR`, and more.

## Custom Signer

Implement `Remitmd::Signer` for HSM, KMS, or multi-sig workflows:

```ruby
class MyHsmSigner
  include Remitmd::Signer

  def sign(message)
    # Delegate to your HSM
    MyHsm.sign(message)
  end

  def address
    "0xYourAddress..."
  end
end

wallet = Remitmd::RemitWallet.new(signer: MyHsmSigner.new)
```

## Chains

```ruby
Remitmd::RemitWallet.new(private_key: key, chain: "base")          # Base mainnet (default)
Remitmd::RemitWallet.new(private_key: key, chain: "base_sepolia")  # Base Sepolia testnet
```

## License

MIT — see [LICENSE](LICENSE)

[Documentation](https://remit.md/docs) · [Protocol Spec](https://remit.md) · [GitHub](https://github.com/remit-md/sdk)
