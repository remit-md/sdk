# @remitmd/ows-policy

OWS policy executable for the [Remit](https://remit.md) payment protocol.

Evaluates signing requests against 4 configurable rules before allowing an agent's OWS wallet to sign:

1. **Chain lock** — restrict signing to specific EVM chains (CAIP-2 IDs)
2. **Contract allowlist** — restrict which contracts the agent can interact with
3. **Per-transaction cap** — limit the USDC amount in a single transaction
4. **Daily cap** — limit cumulative daily USDC spending

## Install

```bash
npm install -g @remitmd/ows-policy
```

## Usage

The policy executable reads a `PolicyContext` JSON from stdin and writes a `PolicyResult` to stdout. OWS invokes it automatically when an API key with an attached policy is used for signing.

### 1. Create a policy file

Copy one of the examples from `examples/` and customize:

```json
{
  "id": "remit-base-mainnet",
  "name": "Remit Base Mainnet Policy",
  "version": 1,
  "created_at": "2026-03-25T00:00:00Z",
  "rules": [
    { "type": "allowed_chains", "chain_ids": ["eip155:8453"] }
  ],
  "executable": "remit-policy",
  "config": {
    "chain_ids": ["eip155:8453"],
    "allowed_contracts": [
      "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      "0x3120f396ff6a9afc5a9d92e28796082f1429e024"
    ],
    "max_tx_usdc": 500,
    "daily_limit_usdc": 5000
  },
  "action": "deny"
}
```

### 2. Register with OWS

```bash
ows policy create --file remit-base-mainnet.json
ows key create --name my-agent --wallet remit-agent --policy remit-base-mainnet
```

### 3. Use with Remit MCP/SDK

Set `OWS_WALLET_ID` and `OWS_API_KEY` in your environment — the Remit SDK and MCP server auto-detect OWS.

## Configuration

All fields in `config` are optional. Omitting a field disables that rule.

| Field | Type | Description |
|-------|------|-------------|
| `chain_ids` | `string[]` | Allowed CAIP-2 chain IDs (e.g., `["eip155:8453"]` for Base) |
| `allowed_contracts` | `string[]` | Contract addresses the agent can transact with |
| `max_tx_usdc` | `number` | Max USDC amount per transaction (in dollars) |
| `daily_limit_usdc` | `number` | Max cumulative daily USDC spending (in dollars) |

## Protocol

- **stdin:** `PolicyContext` JSON (provided by OWS)
- **stdout:** `{ "allow": true }` or `{ "allow": false, "reason": "..." }`
- **exit 0** = use the JSON result
- **non-zero exit** = deny
- **timeout (5s)** = deny
- **malformed JSON** = deny

The policy is **fail-closed**: any error, malformed input, or exception results in denial.

## Examples

Three example policy files are included:

- `examples/chain-lock-only.json` — Base-only chain lock, no spending limits (default for `remit init`)
- `examples/base-mainnet.json` — Full policy with contract allowlist + spending caps
- `examples/base-sepolia.json` — Testnet policy with contract allowlist, no spending caps

## ERC-20 Amount Decoding

The per-tx and daily cap rules decode USDC amounts from ERC-20 calldata:

- `transfer(address,uint256)` — decoded
- `approve(address,uint256)` — decoded
- `transferFrom(address,address,uint256)` — decoded
- Unknown selectors — skipped (contract allowlist is the guard)

## License

MIT
