# remit.md Ruby SDK

> [Skill MD](https://remit.md) · [Docs](https://remit.md/docs) · [Agent Spec](https://remit.md/agent.md)

Universal payment protocol for AI agents - Ruby client library.

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

wallet = Remitmd::RemitWallet.new(private_key: ENV["REMITMD_KEY"])

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
# Auto-detects: CliSigner (remit CLI) > REMITMD_KEY
# Optional: REMITMD_CHAIN (default: "base"), REMITMD_API_URL
```

Permits are auto-signed. Every payment method fetches the on-chain USDC nonce, signs an EIP-2612 permit, and includes it automatically.

## CLI Signer (Recommended)

The CLI signer delegates key management to the `remit` CLI binary, which holds your encrypted keystore at `~/.remit/keys/`. No private key in your environment -- just install the CLI and set a password.

```bash
# Install the CLI
# macOS:   brew install remit-md/tap/remit
# Windows: winget install remit-md.remit
# Linux:   curl -fsSL https://remit.md/install.sh | sh

export REMIT_SIGNER_KEY=your-keystore-password
```

```ruby
# Explicit
signer = Remitmd::CliSigner.new
wallet = Remitmd::RemitWallet.new(signer: signer)

# Or auto-detect from env (recommended)
wallet = Remitmd::RemitWallet.from_env # detects remit CLI automatically
```

`RemitWallet.from_env` detects signing methods automatically. Priority: `CliSigner` (CLI + keystore + password) > `REMITMD_KEY`.

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
tab = wallet.create_tab("0xProvider...", 50.00, 0.003)

# Provider charges with EIP-712 signature
contracts = wallet.get_contracts
sig = wallet.sign_tab_charge(contracts.tab, tab.id, 3_000_000, 1)
wallet.charge_tab(tab.id, 0.003, 0.003, 1, sig)

# Close when done - unused funds return
wallet.close_tab(tab.id)
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
dep = wallet.place_deposit("0xCounterpart...", 100.00, expires_in_secs: 86_400)
wallet.return_deposit(dep.id)
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
mock.total_paid_to(address)       # BigDecimal - sum of all payments to address
mock.transaction_count            # Integer
mock.balance                      # BigDecimal - current balance
mock.transactions                 # Array<Transaction>
mock.set_balance(amount)          # Override starting balance
mock.reset                        # Clear all state
```

## All Methods

```ruby
# Contract discovery (cached per session)
wallet.get_contracts                                        # Hash

# Balance & analytics
wallet.balance                                              # Balance
wallet.history(limit: 50, offset: 0)                       # TransactionList
wallet.reputation(address)                                  # Reputation
wallet.spending_summary                                     # SpendingSummary
wallet.remaining_budget                                     # Budget

# Direct payment
wallet.pay(to, amount, memo: nil, permit: nil)              # Transaction

# Escrow
wallet.create_escrow(payee, amount, memo: nil, expires_in_secs: nil, permit: nil)  # Escrow
wallet.claim_start(escrow_id)                               # Escrow
wallet.release_escrow(escrow_id, memo: nil)                 # Transaction
wallet.cancel_escrow(escrow_id)                             # Transaction
wallet.get_escrow(escrow_id)                                # Escrow

# Tabs
wallet.create_tab(provider, limit, per_unit, expires_in_secs: 86_400, permit: nil)  # Tab
wallet.charge_tab(tab_id, amount, cumulative, call_count, provider_sig)              # TabCharge
wallet.close_tab(tab_id, final_amount: nil, provider_sig: nil)                       # Tab

# Tab provider (signing charges)
wallet.sign_tab_charge(tab_contract, tab_id, total_charged, call_count)  # String

# EIP-2612 Permit (auto-signed when omitted from payment methods)
wallet.sign_permit(spender, amount, deadline: nil)                       # PermitSignature
wallet.sign_usdc_permit(spender, value, deadline, nonce, usdc_address: nil) # PermitSignature

# Streams
wallet.create_stream(payee, rate_per_second, max_total, permit: nil)  # Stream
wallet.close_stream(stream_id)                              # Stream
wallet.withdraw_stream(stream_id)                           # Transaction

# Bounties
wallet.create_bounty(amount, task, deadline, max_attempts: 10, permit: nil)  # Bounty
wallet.submit_bounty(bounty_id, evidence_hash)              # BountySubmission
wallet.award_bounty(bounty_id, submission_id)               # Bounty

# Deposits
wallet.place_deposit(provider, amount, expires_in_secs: 3600, permit: nil)  # Deposit
wallet.return_deposit(deposit_id)                           # Transaction

# Webhooks
wallet.register_webhook(url, events, chains: nil)           # Webhook

# Operator links (optional: messages: [], agent_name: "")
wallet.create_fund_link                                     # LinkResponse
wallet.create_withdraw_link(messages: ["Withdraw"], agent_name: "my-agent")  # LinkResponse

# Testnet
wallet.mint(amount)                                         # Hash {tx_hash, balance}
```

## Error Handling

All errors are `Remitmd::RemitError` with structured fields and enriched details:

```ruby
begin
  wallet.pay("0xRecipient...", 100.00)
rescue Remitmd::RemitError => e
  puts e.code     # "INSUFFICIENT_BALANCE"
  puts e.message  # "Insufficient USDC balance: have $5.00, need $100.00"
  puts e.doc_url  # Direct link to error documentation
  puts e.context  # Hash: {"required" => "100.00", "available" => "5.00", ...}
end
```

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

## Advanced

### Manual Permit Signing

Permits are auto-signed by default. If you need manual control (custom deadline, pre-signed permits, or offline signing), pass a `PermitSignature` explicitly:

```ruby
# sign_permit: convenience - auto-fetches nonce, converts amount to base units
permit = wallet.sign_permit("0xRouterAddress...", 5.00, deadline: Time.now.to_i + 7200)
tx = wallet.pay("0xRecipient...", 5.00, permit: permit)

# sign_usdc_permit: full control - raw base units, explicit nonce
permit = wallet.sign_usdc_permit(
  "0xRouterAddress...",   # spender
  5_000_000,              # value in base units (6 decimals)
  Time.now.to_i + 3600,  # deadline
  0,                      # nonce
  usdc_address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
)
tx = wallet.pay("0xRecipient...", 5.00, permit: permit)
```

## License

MIT - see [LICENSE](LICENSE)

[Documentation](https://remit.md/docs) · [Protocol Spec](https://remit.md) · [GitHub](https://github.com/remit-md/sdk)
