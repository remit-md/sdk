# remit.md / sdk

Python and TypeScript SDKs for the [remit.md](https://remit.md) payment protocol.
Let AI agents pay for tools, data, and services — one env var, no crypto experience required.

## Quickstart (3 steps)

### Step 1 — Get your agent key

The SDK generates a wallet keypair automatically. Set it as an environment variable:

```bash
export REMITMD_KEY=0xYourAgentKey
```

Or in a `.env` file:

```
REMITMD_KEY=0xYourAgentKey
```

### Step 2 — Install the SDK and pay

#### Python

```bash
pip install remitmd
```

```python
from remitmd import Wallet

wallet = Wallet()  # reads REMITMD_KEY from environment
print(f"Balance: ${wallet.balance:.2f}")

# Pay an API provider
tx = await wallet.pay_direct("0xProviderAddress", 0.50, memo="gpt-4o call")
print(f"Paid: {tx.id}")
```

#### TypeScript / Node.js

```bash
npm install @remitmd/sdk
```

```typescript
import { Wallet } from '@remitmd/sdk';

const wallet = new Wallet(); // reads REMITMD_KEY from process.env

// Pay an API provider
const tx = await wallet.payDirect('0xProviderAddress', 0.50, 'gpt-4o call');
console.log('Paid:', tx.id);
```

#### MCP (Claude Desktop / Cursor)

```json
{
  "mcpServers": {
    "remit": {
      "command": "npx",
      "args": ["@remitmd/mcp"],
      "env": {
        "REMITMD_KEY": "0xYourAgentKey"
      }
    }
  }
}
```

---

## Framework Integrations

### LangChain (Python)

```python
from langchain.tools import tool
from remitmd import Wallet

wallet = Wallet()

@tool
async def pay_for_data(provider_address: str, amount: float, description: str) -> str:
    """Pay a data provider using remit.md."""
    tx = await wallet.pay_direct(provider_address, amount, memo=description)
    return f"Payment sent: {tx.id}"
```

### CrewAI (Python)

```python
from crewai import Agent
from crewai.tools import BaseTool
from remitmd import Wallet

wallet = Wallet()

class PayTool(BaseTool):
    name: str = "pay_provider"
    description: str = "Pay a service provider for completed work"

    def _run(self, address: str, amount: float, note: str) -> str:
        import asyncio
        tx = asyncio.run(wallet.pay_direct(address, amount, memo=note))
        return f"Paid ${amount:.2f}: {tx.id}"

agent = Agent(role="AI Buyer", tools=[PayTool()])
```

### Vercel AI SDK (TypeScript)

```typescript
import { tool } from 'ai';
import { z } from 'zod';
import { Wallet } from '@remitmd/sdk';

const wallet = new Wallet();

export const payTool = tool({
  description: 'Pay a service provider',
  parameters: z.object({
    address: z.string().describe('Provider wallet address'),
    amount: z.number().describe('Amount in USD'),
    memo: z.string().describe('Payment description'),
  }),
  execute: async ({ address, amount, memo }) => {
    const tx = await wallet.payDirect(address, amount, memo);
    return { txId: tx.id, paid: amount };
  },
});
```

### OpenAI Agents (Python)

```python
from agents import function_tool
from remitmd import Wallet

wallet = Wallet()

@function_tool
async def pay_provider(address: str, amount: float, note: str) -> dict:
    """Pay a service provider via remit.md."""
    tx = await wallet.pay_direct(address, amount, memo=note)
    return {"tx_id": tx.id, "amount": amount}
```

---

## Payment Types

| Type | Use Case | Method |
|------|----------|--------|
| Direct | One-off service call | `pay_direct` / `payDirect` |
| Tab | Metered API access (pay per call) | `open_tab` / `openTab` |
| Escrow | Work with acceptance criteria | `create_escrow` / `createEscrow` |
| Stream | Time-based work (pay per second) | `open_stream` / `openStream` |
| Bounty | Competitive task completion | `post_bounty` / `postBounty` |
| Deposit | Refundable collateral | `lock_deposit` / `lockDeposit` |

---

## Testing

No API key needed for unit tests:

```python
from remitmd.testing import MockRemit

mock = MockRemit()  # in-memory, <1ms, no network
async with mock.session() as wallet:
    tx = await wallet.pay_direct("0xAnyone", 1.00)
    assert tx.status == "confirmed"
```

```typescript
import { MockRemit } from '@remitmd/sdk/testing';

const mock = new MockRemit();
const wallet = await mock.session();
const tx = await wallet.payDirect('0xAnyone', 1.00, 'test');
```

---

## Error Reference

| Error Code | Meaning | Fix |
|------------|---------|-----|
| `MISSING_KEY` | `REMITMD_KEY` not set | Set the env var: `export REMITMD_KEY=0x...` |
| `INSUFFICIENT_BALANCE` | Not enough funds | Ask your operator to fund via one-time link |
| `INVALID_KEY` | Key format invalid | Ensure key starts with `0x` and is 66 hex characters |
| `RATE_LIMITED` | Too many requests | Back off and retry — the SDK handles this automatically |

---

## Configuration

| Environment Variable | Required | Default | Description |
|---------------------|----------|---------|-------------|
| `REMITMD_KEY` | Yes | — | Agent wallet private key (auto-generated or from registration) |
| `REMITMD_API_URL` | No | `https://api.remit.md` | API server URL |
| `REMITMD_CHAIN` | No | `base` | Chain name (`base` or `base-sepolia` for testnet) |
| `REMITMD_TESTNET` | No | `false` | Set to `true` to use testnet |

---

## Examples

- **`examples/demo-agent/`** — Python AI agent demonstrating tab, escrow, stream, and bounty lifecycles
- **`examples/demo-services/`** — TypeScript microservices accepting remit.md payments (LLM API, Data API, Code Review)

---

## License

MIT — see [LICENSE](LICENSE).
