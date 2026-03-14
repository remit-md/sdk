# remit.md Python SDK

Universal payment protocol for AI agents — Python client library.

[![CI](https://github.com/remit-md/sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/remit-md/sdk/actions/workflows/ci.yml)
[![PyPI](https://img.shields.io/pypi/v/remitmd)](https://pypi.org/project/remitmd/)

## Installation

```bash
pip install remitmd
```

With framework integrations:

```bash
pip install remitmd[langchain]    # LangChain tools
pip install remitmd[crewai]       # CrewAI tools
pip install remitmd[autogen]      # AutoGen tools
pip install remitmd[openai-agents]  # OpenAI Agents tools
```

## Quickstart

```python
from remitmd import Wallet

# From environment variables (REMITMD_KEY, REMITMD_CHAIN)
wallet = Wallet.from_env()

# Or with explicit key
wallet = Wallet(private_key="0x...", chain="base")

# Send 1.50 USDC
tx = await wallet.pay_direct("0xRecipient...", 1.50, memo="inference fee")
print(tx.tx_hash)
```

## Payment Models

### Direct Payment

```python
tx = await wallet.pay_direct("0xRecipient...", 5.00, memo="AI task")
```

### Escrow

```python
from remitmd import Invoice

invoice = Invoice(to="0xContractor...", amount=100.00, memo="Code review")
escrow = await wallet.pay(invoice)

# Work happens...
await wallet.release_escrow(escrow.id)   # pay the contractor
# or
await wallet.cancel_escrow(escrow.id)    # refund yourself
```

### Metered Tab (off-chain billing)

```python
tab = await wallet.open_tab("0xProvider...", limit=50.0, per_unit=0.003)

# Hundreds of off-chain debits — zero gas, instant
# (provider calls debit on their side)

# One on-chain settlement when done
await wallet.close_tab(tab.id)
```

### Payment Stream

```python
stream = await wallet.open_stream("0xWorker...", rate=0.001)
# Worker receives 0.001 USDC/second

await wallet.close_stream(stream.id)
```

### Bounty

```python
bounty = await wallet.post_bounty(
    amount=25.0,
    task="Summarise top 10 EIPs of 2025",
    deadline=1700000000,
)

# Any agent can submit work; you decide the winner
await wallet.award_bounty(bounty.id, "0xWinner...")
```

### Security Deposit

```python
deposit = await wallet.place_deposit("0xCounterpart...", amount=100.0, expires=86400)
```

## Testing with MockRemit

MockRemit gives you a zero-network, zero-latency test double. No API key needed.

```python
import pytest
from remitmd import MockRemit

@pytest.fixture
def wallet():
    mock = MockRemit()
    return mock.wallet("0xAgent...")

async def test_agent_pays(wallet):
    mock = wallet._mock  # access the underlying mock
    tx = await wallet.pay_direct("0xProvider...", 0.003)
    assert mock.was_paid("0xProvider...", 0.003)
```

## All Methods

```python
# Direct payment
await wallet.pay_direct(to, amount, memo="")              # Transaction

# Escrow
await wallet.pay(invoice)                                   # Escrow
await wallet.claim_start(invoice_id)                        # Escrow
await wallet.submit_evidence(invoice_id, uri, milestone=0)  # Transaction
await wallet.release_escrow(invoice_id)                     # Escrow
await wallet.release_milestone(invoice_id, index)           # Escrow
await wallet.cancel_escrow(invoice_id)                      # Escrow

# Tabs
await wallet.open_tab(to, limit, per_unit, expires=86400)   # Tab
await wallet.close_tab(tab_id)                              # Tab

# Streams
await wallet.open_stream(to, rate, max_duration=3600)       # Stream
await wallet.close_stream(stream_id)                        # Transaction

# Bounties
await wallet.post_bounty(amount, task, deadline, ...)       # Bounty
await wallet.submit_bounty(bounty_id, evidence_uri)         # Transaction
await wallet.award_bounty(bounty_id, winner)                # Transaction

# Deposits
await wallet.place_deposit(to, amount, expires)             # Deposit

# Status & analytics
await wallet.status()                                       # WalletStatus
await wallet.balance()                                      # float

# Webhooks
await wallet.register_webhook(url, events, chains=None)     # Webhook

# Operator links
await wallet.create_fund_link()                             # LinkResponse
await wallet.create_withdraw_link()                         # LinkResponse

# Testnet
await wallet.request_testnet_funds()                        # Transaction
```

## Error Handling

All errors are `RemitError` with machine-readable codes:

```python
from remitmd import RemitError

try:
    await wallet.pay_direct("invalid", 1.00)
except RemitError as e:
    print(e.code)     # "INVALID_ADDRESS"
    print(e.message)  # Human-readable description
```

## Chains

```python
Wallet(private_key=key, chain="base")          # Base mainnet (default)
Wallet(private_key=key, chain="base-sepolia")  # Base Sepolia testnet
```

## License

MIT — see [LICENSE](LICENSE)

[Documentation](https://remit.md/docs) · [Protocol Spec](https://remit.md) · [GitHub](https://github.com/remit-md/sdk)
