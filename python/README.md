# remit.md Python SDK

> [Skill MD](https://remit.md) · [Docs](https://remit.md/docs) · [Agent Spec](https://remit.md/agent.md)

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

wallet = Wallet.from_env()  # REMITMD_KEY, REMITMD_CHAIN

tx = await wallet.pay_direct("0xRecipient...", 1.50, memo="inference fee")
print(tx.tx_hash)
```

That's it. USDC approval is handled automatically.

## Secure Wallet with OWS

The [Open Wallet Standard](https://openwallet.sh) replaces raw private keys with encrypted local storage and policy-gated signing. Keys never leave the vault — the SDK signs through OWS's FFI layer.

### Setup

```bash
# Install OWS
pip install open-wallet-standard
# or: curl -fsSL https://docs.openwallet.sh/install.sh | bash

# Create a wallet + policy + API key in one command
ows wallet create --name remit-my-agent
```

Or use the Remit CLI which does all of this automatically:

```bash
remit init  # creates wallet, chain-lock policy, API key, prints MCP config
```

### Usage

```python
from remitmd import Wallet, OwsSigner

# Option 1: Direct signer construction
signer = OwsSigner(wallet_id="remit-my-agent", ows_api_key=os.environ.get("OWS_API_KEY"))
wallet = Wallet(signer=signer, chain="base")

# Option 2: Environment-based (set OWS_WALLET_ID + OWS_API_KEY)
signer = OwsSigner(
    wallet_id=os.environ["OWS_WALLET_ID"],
    ows_api_key=os.environ.get("OWS_API_KEY"),
)
wallet = Wallet(signer=signer)
```

Everything works the same — payments, permits, x402:

```python
tx = await wallet.pay_direct("0xRecipient...", 1.50, memo="inference fee")
```

### Environment Variables

| Variable | Purpose | Required |
|----------|---------|----------|
| `OWS_WALLET_ID` | OWS wallet name or UUID | Yes (for OWS path) |
| `OWS_API_KEY` | API key token for headless signing | Recommended |
| `REMITMD_CHAIN` | `"base"` or `"base-sepolia"` | No (defaults to `"base"`) |

### Install with OWS support

```bash
pip install remitmd[ows]
```

### Custom Signer

Implement the `Signer` ABC for custom signing backends:

```python
from remitmd import Signer, Wallet

class MySigner(Signer):
    def get_address(self) -> str:
        return "0x..."

    async def sign_typed_data(self, domain, types, value) -> str:
        return "0x..."

wallet = Wallet(signer=MySigner())
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
stream = await wallet.open_stream("0xWorker...", rate=0.001, max_total=10.0)
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
# Contract discovery (cached per session)
contracts = await wallet.get_contracts()                     # dict

# Direct payment
await wallet.pay_direct(to, amount, memo="")                 # Transaction

# Escrow
await wallet.pay(invoice)                                    # Escrow
await wallet.claim_start(invoice_id)                         # Escrow
await wallet.submit_evidence(invoice_id, uri)                # Escrow
await wallet.release_escrow(invoice_id)                      # Escrow
await wallet.release_milestone(invoice_id, index)            # Escrow
await wallet.cancel_escrow(invoice_id)                       # Escrow

# Tabs
await wallet.open_tab(to, limit, per_unit, expires=86400)    # Tab
await wallet.close_tab(tab_id, final_amount=0, provider_sig="0x")  # Tab
await wallet.charge_tab(tab_id, amount, cumulative, call_count, provider_sig)  # TabCharge

# Tab provider (signing charges)
sig = await wallet.sign_tab_charge(tab_contract, tab_id, total_charged, call_count)  # str

# Streams
await wallet.open_stream(to, rate, max_total)                # Stream
await wallet.close_stream(stream_id)                         # Transaction

# Bounties
await wallet.post_bounty(amount, task, deadline, max_attempts=10)  # Bounty
await wallet.submit_bounty(bounty_id, evidence_hash, evidence_uri=None)  # dict
await wallet.award_bounty(bounty_id, submission_id)          # Bounty

# Deposits
await wallet.place_deposit(to, amount, expires)              # Deposit
await wallet.return_deposit(deposit_id)                      # Transaction

# Status & analytics
await wallet.status()                                        # WalletStatus

# Webhooks
await wallet.register_webhook(url, events, chains=None)      # Webhook

# Operator links (optional: messages=[], agent_name="")
await wallet.create_fund_link()                              # LinkResponse
await wallet.create_withdraw_link(messages=["Withdraw"], agent_name="my-agent")  # LinkResponse

# Testnet
await wallet.mint(amount)                                    # dict {tx_hash, balance}

# x402 (HTTP 402 auto-pay)
response, payment = await wallet.x402_fetch(url, max_auto_pay_usdc=0.10)
```

## Error Handling

All errors are `RemitError` with machine-readable codes and actionable details:

```python
from remitmd import RemitError

try:
    await wallet.pay_direct("0xRecipient...", 100.00)
except RemitError as e:
    print(e.code)     # "INSUFFICIENT_BALANCE"
    print(e.message)  # "Insufficient USDC balance: have $5.00, need $100.00"
    # Enriched errors include details with actual numbers:
    # e.details = {"required": "100.00", "available": "5.00",
    #              "required_units": 100000000, "available_units": 5000000}
```

## Chains

```python
Wallet(private_key=key, chain="base")          # Base mainnet (default)
Wallet(private_key=key, chain="base-sepolia")  # Base Sepolia testnet
```

## Advanced: Manual Permits

All payment methods auto-sign EIP-2612 USDC permits internally. If you need explicit control (custom spenders, pre-signed permits, multi-step workflows), you can sign and pass them manually:

```python
contracts = await wallet.get_contracts()
permit = await wallet.sign_permit(contracts["router"], 5.0)
tx = await wallet.pay_direct("0xRecipient...", 5.00, permit=permit)
```

The `spender` must match the contract handling the payment:

| Payment type | Spender |
|---|---|
| Direct | `contracts["router"]` |
| Escrow | `contracts["escrow"]` |
| Tab | `contracts["tab"]` |
| Stream | `contracts["stream"]` |
| Bounty | `contracts["bounty"]` |
| Deposit | `contracts["deposit"]` |

For lower-level control over nonce, deadline, and USDC address:

```python
permit = await wallet.sign_usdc_permit(
    spender=contracts["router"],
    value=5_000_000,           # raw USDC base units (6 decimals)
    deadline=int(time.time()) + 3600,
    nonce=0,
)
```

## License

MIT — see [LICENSE](LICENSE)

[Documentation](https://remit.md/docs) · [Protocol Spec](https://remit.md) · [GitHub](https://github.com/remit-md/sdk)
