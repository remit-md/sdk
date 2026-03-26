import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { evaluate, decodeUsdcAmount } from "../src/remit-policy.js";
import type { PolicyContext, PolicyConfig } from "../src/remit-policy.js";

// ── Test helpers ───────────────────────────────────────────────────────

/** Build a minimal valid PolicyContext with overrides. */
function ctx(overrides: {
  chain_id?: string;
  to?: string;
  data?: string;
  daily_total?: string;
  config?: Partial<PolicyConfig>;
} = {}): PolicyContext {
  return {
    chain_id: overrides.chain_id ?? "eip155:8453",
    wallet_id: "test-wallet",
    api_key_id: "test-key",
    transaction: {
      to: overrides.to ?? "0x3120f396ff6a9afc5a9d92e28796082f1429e024",
      value: "0",
      data: overrides.data ?? "0x",
      raw_hex: "0x",
    },
    spending: {
      daily_total: overrides.daily_total ?? "0",
      date: "2026-03-25",
    },
    timestamp: "2026-03-25T14:30:00Z",
    policy_config: {
      chain_ids: undefined,
      allowed_contracts: undefined,
      max_tx_usdc: undefined,
      daily_limit_usdc: undefined,
      ...overrides.config,
    },
  };
}

// ERC-20 calldata helpers
// transfer(address, uint256): selector 0xa9059cbb
function transferCalldata(to: string, amount: bigint): string {
  const selector = "a9059cbb";
  const toParam = to.replace("0x", "").toLowerCase().padStart(64, "0");
  const amountParam = amount.toString(16).padStart(64, "0");
  return "0x" + selector + toParam + amountParam;
}

// approve(address, uint256): selector 0x095ea7b3
function approveCalldata(spender: string, amount: bigint): string {
  const selector = "095ea7b3";
  const spenderParam = spender.replace("0x", "").toLowerCase().padStart(64, "0");
  const amountParam = amount.toString(16).padStart(64, "0");
  return "0x" + selector + spenderParam + amountParam;
}

// transferFrom(address, address, uint256): selector 0x23b872dd
function transferFromCalldata(from: string, to: string, amount: bigint): string {
  const selector = "23b872dd";
  const fromParam = from.replace("0x", "").toLowerCase().padStart(64, "0");
  const toParam = to.replace("0x", "").toLowerCase().padStart(64, "0");
  const amountParam = amount.toString(16).padStart(64, "0");
  return "0x" + selector + fromParam + toParam + amountParam;
}

const ROUTER = "0x3120f396ff6a9afc5a9d92e28796082f1429e024";
const ESCROW = "0x47de7cdd757e3765d36c083dab59b2c5a9d249f2";
const USDC = "0x2d846325766921935f37d5b4478196d3ef93707c";
const ATTACKER = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";

// ── decodeUsdcAmount ───────────────────────────────────────────────────

describe("decodeUsdcAmount", () => {
  it("decodes transfer(address,uint256)", () => {
    // $100 USDC = 100_000_000 base units
    const data = transferCalldata(ROUTER, 100_000_000n);
    assert.equal(decodeUsdcAmount(data), 100_000_000n);
  });

  it("decodes approve(address,uint256)", () => {
    const data = approveCalldata(ROUTER, 500_000_000n);
    assert.equal(decodeUsdcAmount(data), 500_000_000n);
  });

  it("decodes transferFrom(address,address,uint256)", () => {
    const data = transferFromCalldata(USDC, ROUTER, 250_000_000n);
    assert.equal(decodeUsdcAmount(data), 250_000_000n);
  });

  it("returns null for empty data", () => {
    assert.equal(decodeUsdcAmount("0x"), null);
    assert.equal(decodeUsdcAmount(""), null);
  });

  it("returns null for unknown selector", () => {
    assert.equal(decodeUsdcAmount("0xdeadbeef" + "00".repeat(64)), null);
  });

  it("returns null for truncated calldata", () => {
    // Only selector, no params
    assert.equal(decodeUsdcAmount("0xa9059cbb"), null);
  });

  it("handles zero amount", () => {
    const data = transferCalldata(ROUTER, 0n);
    assert.equal(decodeUsdcAmount(data), 0n);
  });

  it("handles large amount (max uint256-ish)", () => {
    const large = 2n ** 128n;
    const data = transferCalldata(ROUTER, large);
    assert.equal(decodeUsdcAmount(data), large);
  });
});

// ── Rule 1: Chain lock ─────────────────────────────────────────────────

describe("Rule 1: Chain lock", () => {
  it("allows when chain matches", () => {
    const result = evaluate(ctx({
      chain_id: "eip155:8453",
      config: { chain_ids: ["eip155:8453"] },
    }));
    assert.equal(result.allow, true);
  });

  it("allows when chain is one of several", () => {
    const result = evaluate(ctx({
      chain_id: "eip155:84532",
      config: { chain_ids: ["eip155:8453", "eip155:84532"] },
    }));
    assert.equal(result.allow, true);
  });

  it("denies when chain not in list", () => {
    const result = evaluate(ctx({
      chain_id: "eip155:1",
      config: { chain_ids: ["eip155:8453"] },
    }));
    assert.equal(result.allow, false);
    assert.ok(result.reason?.includes("eip155:1"));
  });

  it("skips when chain_ids not configured", () => {
    const result = evaluate(ctx({
      chain_id: "eip155:999",
      config: { chain_ids: undefined },
    }));
    assert.equal(result.allow, true);
  });

  it("skips when chain_ids is empty array", () => {
    const result = evaluate(ctx({
      chain_id: "eip155:999",
      config: { chain_ids: [] },
    }));
    assert.equal(result.allow, true);
  });

  it("denies when chain_id is missing from context", () => {
    const c = ctx({ config: { chain_ids: ["eip155:8453"] } });
    c.chain_id = "";
    const result = evaluate(c);
    assert.equal(result.allow, false);
  });
});

// ── Rule 2: Contract allowlist ─────────────────────────────────────────

describe("Rule 2: Contract allowlist", () => {
  it("allows when contract in list", () => {
    const result = evaluate(ctx({
      to: ROUTER,
      config: { allowed_contracts: [ROUTER, ESCROW] },
    }));
    assert.equal(result.allow, true);
  });

  it("denies when contract not in list", () => {
    const result = evaluate(ctx({
      to: ATTACKER,
      config: { allowed_contracts: [ROUTER, ESCROW] },
    }));
    assert.equal(result.allow, false);
    assert.ok(result.reason?.includes("not in allowed contracts"));
  });

  it("case-insensitive comparison", () => {
    const result = evaluate(ctx({
      to: ROUTER.toUpperCase(),
      config: { allowed_contracts: [ROUTER.toLowerCase()] },
    }));
    assert.equal(result.allow, true);
  });

  it("skips when allowed_contracts not configured", () => {
    const result = evaluate(ctx({
      to: ATTACKER,
      config: { allowed_contracts: undefined },
    }));
    assert.equal(result.allow, true);
  });

  it("skips when allowed_contracts is empty", () => {
    const result = evaluate(ctx({
      to: ATTACKER,
      config: { allowed_contracts: [] },
    }));
    assert.equal(result.allow, true);
  });

  it("denies when transaction.to is missing", () => {
    const c = ctx({ config: { allowed_contracts: [ROUTER] } });
    c.transaction.to = "";
    const result = evaluate(c);
    assert.equal(result.allow, false);
    assert.ok(result.reason?.includes("missing target address"));
  });
});

// ── Rule 3: Per-tx USDC cap ───────────────────────────────────────────

describe("Rule 3: Per-tx USDC cap", () => {
  it("allows when amount under limit", () => {
    // $100 transfer, limit $500
    const data = transferCalldata(ROUTER, 100_000_000n);
    const result = evaluate(ctx({
      data,
      config: { max_tx_usdc: 500 },
    }));
    assert.equal(result.allow, true);
  });

  it("allows when amount equals limit", () => {
    // $500 exactly
    const data = transferCalldata(ROUTER, 500_000_000n);
    const result = evaluate(ctx({
      data,
      config: { max_tx_usdc: 500 },
    }));
    assert.equal(result.allow, true);
  });

  it("denies when amount exceeds limit", () => {
    // $501 transfer, limit $500
    const data = transferCalldata(ROUTER, 501_000_000n);
    const result = evaluate(ctx({
      data,
      config: { max_tx_usdc: 500 },
    }));
    assert.equal(result.allow, false);
    assert.ok(result.reason?.includes("exceeds per-tx limit"));
  });

  it("skips when max_tx_usdc not configured", () => {
    const data = transferCalldata(ROUTER, 999_999_000_000n); // $999,999
    const result = evaluate(ctx({
      data,
      config: { max_tx_usdc: undefined },
    }));
    assert.equal(result.allow, true);
  });

  it("skips for unknown calldata selector", () => {
    const result = evaluate(ctx({
      data: "0xdeadbeef" + "00".repeat(64),
      config: { max_tx_usdc: 1 },
    }));
    assert.equal(result.allow, true);
  });

  it("handles approve calldata", () => {
    // approve for $600, limit $500
    const data = approveCalldata(ROUTER, 600_000_000n);
    const result = evaluate(ctx({
      data,
      config: { max_tx_usdc: 500 },
    }));
    assert.equal(result.allow, false);
  });

  it("handles transferFrom calldata", () => {
    // transferFrom for $200, limit $500
    const data = transferFromCalldata(USDC, ROUTER, 200_000_000n);
    const result = evaluate(ctx({
      data,
      config: { max_tx_usdc: 500 },
    }));
    assert.equal(result.allow, true);
  });

  it("denies on negative max_tx_usdc", () => {
    const result = evaluate(ctx({
      config: { max_tx_usdc: -1 },
    }));
    assert.equal(result.allow, false);
    assert.ok(result.reason?.includes("Invalid max_tx_usdc"));
  });
});

// ── Rule 4: Daily USDC cap ────────────────────────────────────────────

describe("Rule 4: Daily USDC cap", () => {
  it("allows when daily total under limit", () => {
    // $100 already spent, $200 this tx, limit $5000
    const data = transferCalldata(ROUTER, 200_000_000n);
    const result = evaluate(ctx({
      data,
      daily_total: "100000000", // $100 in base units
      config: { daily_limit_usdc: 5000 },
    }));
    assert.equal(result.allow, true);
  });

  it("denies when daily total would exceed limit", () => {
    // $4900 already spent, $200 this tx = $5100 > $5000
    const data = transferCalldata(ROUTER, 200_000_000n);
    const result = evaluate(ctx({
      data,
      daily_total: "4900000000", // $4900
      config: { daily_limit_usdc: 5000 },
    }));
    assert.equal(result.allow, false);
    assert.ok(result.reason?.includes("exceeding limit"));
  });

  it("allows when projected total equals limit", () => {
    // $4800 + $200 = $5000 exactly
    const data = transferCalldata(ROUTER, 200_000_000n);
    const result = evaluate(ctx({
      data,
      daily_total: "4800000000",
      config: { daily_limit_usdc: 5000 },
    }));
    assert.equal(result.allow, true);
  });

  it("skips when daily_limit_usdc not configured", () => {
    const data = transferCalldata(ROUTER, 999_000_000_000n);
    const result = evaluate(ctx({
      data,
      daily_total: "999000000000",
      config: { daily_limit_usdc: undefined },
    }));
    assert.equal(result.allow, true);
  });

  it("handles zero daily total", () => {
    const data = transferCalldata(ROUTER, 100_000_000n);
    const result = evaluate(ctx({
      data,
      daily_total: "0",
      config: { daily_limit_usdc: 500 },
    }));
    assert.equal(result.allow, true);
  });

  it("denies on invalid daily_total string", () => {
    const result = evaluate(ctx({
      daily_total: "not-a-number",
      config: { daily_limit_usdc: 5000 },
    }));
    assert.equal(result.allow, false);
    assert.ok(result.reason?.includes("not a valid integer"));
  });

  it("denies on negative daily_limit_usdc", () => {
    const result = evaluate(ctx({
      config: { daily_limit_usdc: -1 },
    }));
    assert.equal(result.allow, false);
    assert.ok(result.reason?.includes("Invalid daily_limit_usdc"));
  });
});

// ── Combined rules ────────────────────────────────────────────────────

describe("Combined rules", () => {
  it("chain deny takes priority over contract allow", () => {
    const result = evaluate(ctx({
      chain_id: "eip155:1",
      to: ROUTER,
      config: {
        chain_ids: ["eip155:8453"],
        allowed_contracts: [ROUTER],
      },
    }));
    assert.equal(result.allow, false);
    assert.ok(result.reason?.includes("Chain"));
  });

  it("contract deny takes priority over spending allow", () => {
    const data = transferCalldata(ROUTER, 100_000_000n);
    const result = evaluate(ctx({
      to: ATTACKER,
      data,
      config: {
        allowed_contracts: [ROUTER],
        max_tx_usdc: 500,
      },
    }));
    assert.equal(result.allow, false);
    assert.ok(result.reason?.includes("not in allowed contracts"));
  });

  it("all rules pass together", () => {
    const data = transferCalldata(ROUTER, 100_000_000n);
    const result = evaluate(ctx({
      chain_id: "eip155:8453",
      to: ROUTER,
      data,
      daily_total: "50000000",
      config: {
        chain_ids: ["eip155:8453"],
        allowed_contracts: [ROUTER, ESCROW, USDC],
        max_tx_usdc: 500,
        daily_limit_usdc: 5000,
      },
    }));
    assert.equal(result.allow, true);
  });

  it("all rules disabled = allow everything", () => {
    const result = evaluate(ctx({
      chain_id: "eip155:999",
      to: ATTACKER,
      config: {},
    }));
    assert.equal(result.allow, true);
  });
});

// ── Adversarial scenarios (TLA+ Step 2) ───────────────────────────────

describe("Adversarial scenarios", () => {
  it("split-spending attack: 51st tx breaches daily limit", () => {
    // $4950 already spent in 49 txns, 50th tx for $100
    const data = transferCalldata(ROUTER, 100_000_000n);
    const result = evaluate(ctx({
      data,
      daily_total: "4950000000", // $4950
      config: { daily_limit_usdc: 5000 },
    }));
    // $4950 + $100 = $5050 > $5000 → DENY
    assert.equal(result.allow, false);
  });

  it("unauthorized contract: USDC.transfer to attacker", () => {
    const data = transferCalldata(ATTACKER, 100_000_000n);
    const result = evaluate(ctx({
      to: USDC, // calling USDC contract itself
      data,
      config: {
        allowed_contracts: [ROUTER, ESCROW],
        // Note: USDC not in allowed list
      },
    }));
    assert.equal(result.allow, false);
    assert.ok(result.reason?.includes("not in allowed contracts"));
  });

  it("malformed spending.daily_total doesn't bypass", () => {
    const result = evaluate(ctx({
      daily_total: "abc",
      config: { daily_limit_usdc: 5000 },
    }));
    assert.equal(result.allow, false);
  });
});

// ── Stuttering tests (TLA+ Step 1f) ──────────────────────────────────

describe("Stuttering (determinism)", () => {
  it("same input produces same output", () => {
    const data = transferCalldata(ROUTER, 100_000_000n);
    const input = ctx({
      chain_id: "eip155:8453",
      to: ROUTER,
      data,
      config: {
        chain_ids: ["eip155:8453"],
        allowed_contracts: [ROUTER],
        max_tx_usdc: 500,
      },
    });

    const r1 = evaluate(input);
    const r2 = evaluate(input);
    const r3 = evaluate(input);

    assert.deepEqual(r1, r2);
    assert.deepEqual(r2, r3);
    assert.equal(r1.allow, true);
  });

  it("same denial produces same reason", () => {
    const input = ctx({
      chain_id: "eip155:1",
      config: { chain_ids: ["eip155:8453"] },
    });

    const r1 = evaluate(input);
    const r2 = evaluate(input);

    assert.deepEqual(r1, r2);
    assert.equal(r1.allow, false);
    assert.equal(r1.reason, r2.reason);
  });
});

// ── Edge cases ────────────────────────────────────────────────────────

describe("Edge cases", () => {
  it("empty policy_config = allow", () => {
    const c = ctx();
    c.policy_config = {} as PolicyConfig;
    assert.equal(evaluate(c).allow, true);
  });

  it("null-ish policy_config fields = skip rules", () => {
    const c = ctx();
    c.policy_config = {
      chain_ids: undefined,
      allowed_contracts: undefined,
      max_tx_usdc: undefined,
      daily_limit_usdc: undefined,
    };
    assert.equal(evaluate(c).allow, true);
  });

  it("zero max_tx_usdc denies any nonzero transfer", () => {
    const data = transferCalldata(ROUTER, 1n); // 0.000001 USDC
    const result = evaluate(ctx({
      data,
      config: { max_tx_usdc: 0 },
    }));
    assert.equal(result.allow, false);
  });

  it("zero daily_limit_usdc denies any transfer", () => {
    const data = transferCalldata(ROUTER, 1n);
    const result = evaluate(ctx({
      data,
      daily_total: "0",
      config: { daily_limit_usdc: 0 },
    }));
    assert.equal(result.allow, false);
  });
});
