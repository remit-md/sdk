# remit.md / sdk

Python and TypeScript SDKs for the [remit.md](https://remit.md) payment protocol.

## Python SDK

```bash
pip install remitmd
```

Requires Python 3.10+.

```python
from remitmd import RemitClient, Wallet

wallet = Wallet.create()
client = RemitClient(api_key="...", wallet=wallet)

# Pay for an API call via tab
tab = await client.tabs.open(payee="0x...", deposit="5.00")
voucher = wallet.sign_voucher(tab.id, amount="0.003")
```

**Framework integrations:** LangChain, CrewAI, AutoGen, OpenAI Agents.

**Testing:**
```python
from remitmd.testing import MockRemit

mock = MockRemit()  # No network, <1ms responses
```

## TypeScript SDK

```bash
npm install @remitmd/sdk
```

Requires Node.js 20+.

```typescript
import { RemitClient, Wallet } from '@remitmd/sdk';

const wallet = Wallet.create();
const client = new RemitClient({ apiKey: '...', wallet });

const escrow = await client.escrows.create({
  payee: '0x...', amount: '2.00', description: 'Code review'
});
```

**Integrations:** Vercel AI SDK.

## Examples

- **`examples/demo-agent/`** — Python AI agent demonstrating tab, escrow, stream, and bounty lifecycles
- **`examples/demo-services/`** — Three TypeScript microservices accepting remit.md payments (LLM API, Data API, Code Review)

## License

MIT
