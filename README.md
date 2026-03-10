# remit.md / sdk

Python and TypeScript SDKs for the [remit.md](https://remit.md) payment protocol.

## Quickstart

1. Register at [remit.md](https://remit.md) to get your agent private key.
2. Set the `REMITMD_KEY` environment variable:

```bash
export REMITMD_KEY=0xYourPrivateKey
```

3. Install and use the SDK:

### Python

```bash
pip install remitmd
```

```python
from remitmd import Wallet

# Reads REMITMD_KEY from environment automatically
wallet = Wallet()

# Or pass the key explicitly
wallet = Wallet(private_key="0xYourPrivateKey")

# Pay someone
tx = await wallet.pay_direct("0xRecipient...", 5.00, memo="thanks")

# Open an escrow
escrow = await wallet.create_escrow(
    to="0xRecipient...",
    amount=10.00,
    description="Code review",
    timeout=86400,
)
```

**Framework integrations:** LangChain, CrewAI, AutoGen, OpenAI Agents.

**Testing:**
```python
from remitmd.testing import MockRemit

mock = MockRemit()  # No network, <1ms responses
async with mock.session() as wallet:
    tx = await wallet.pay_direct("0xAnyone", 1.00)
```

### TypeScript

```bash
npm install @remitmd/sdk
```

```typescript
import { Wallet } from '@remitmd/sdk';

// Reads REMITMD_KEY from process.env automatically
const wallet = new Wallet();

// Or pass the key explicitly
const wallet = new Wallet({ privateKey: process.env.REMITMD_KEY });

// Pay someone
const tx = await wallet.payDirect('0xRecipient...', 5.00, 'thanks');

// Open an escrow
const escrow = await wallet.createEscrow({
  to: '0xRecipient...',
  amount: 10.00,
  description: 'Code review',
  timeout: 86400,
});
```

**Integrations:** Vercel AI SDK.

## Examples

- **`examples/demo-agent/`** — Python AI agent demonstrating tab, escrow, stream, and bounty lifecycles
- **`examples/demo-services/`** — Three TypeScript microservices accepting remit.md payments (LLM API, Data API, Code Review)

## Configuration

| Environment Variable | Required | Description |
|---------------------|----------|-------------|
| `REMITMD_KEY` | Yes | Agent private key (0x-prefixed hex). Get it from the operator dashboard. |
| `REMITMD_CHAIN` | No | Chain name (`base` default, `base-sepolia` for testnet) |
| `REMITMD_TESTNET` | No | Set to `1` or `true` to use testnet |

## License

MIT — see [LICENSE](LICENSE).
