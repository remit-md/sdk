#!/usr/bin/env node

/**
 * Remit OWS Policy Executable
 *
 * Evaluates 4 rules against a PolicyContext received on stdin:
 *   1. Chain lock - chain_id must be in policy_config.chain_ids
 *   2. Contract allowlist - transaction.to must be in policy_config.allowed_contracts
 *   3. Per-tx USDC cap - decoded USDC amount must be <= policy_config.max_tx_usdc
 *   4. Daily USDC cap - cumulative daily + this tx must be <= policy_config.daily_limit_usdc
 *
 * Protocol:
 *   - stdout: { "allow": true } or { "allow": false, "reason": "..." }
 *   - exit 0 = use result, non-zero = deny, timeout (5s) = deny, bad JSON = deny
 *
 * Design: fail-closed. Any error, exception, or malformed input results in denial.
 * This is financial infrastructure - a false allow means funds move wrong.
 *
 * @see https://docs.openwallet.sh/ - OWS Policy Engine spec
 */

// ── Types ──────────────────────────────────────────────────────────────

interface PolicyContext {
  chain_id: string;
  wallet_id: string;
  api_key_id: string;
  transaction: {
    to: string;
    value: string;
    data: string;
    raw_hex: string;
  };
  spending: {
    daily_total: string;
    date: string;
  };
  timestamp: string;
  policy_config: PolicyConfig;
}

interface PolicyConfig {
  chain_ids?: string[];
  allowed_contracts?: string[];
  max_tx_usdc?: number;
  daily_limit_usdc?: number;
}

interface PolicyResult {
  allow: boolean;
  reason?: string;
}

// ── Helpers ────────────────────────────────────────────────────────────

function deny(reason: string): PolicyResult {
  return { allow: false, reason };
}

const ALLOW: PolicyResult = { allow: true };

/** Read all of stdin as a string. */
function readStdin(): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: string[] = [];
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk: string) => chunks.push(chunk));
    process.stdin.on("end", () => resolve(chunks.join("")));
    process.stdin.on("error", reject);
  });
}

// ERC-20 function selectors (4-byte keccak256 prefixes)
const SELECTOR_TRANSFER = "a9059cbb"; // transfer(address,uint256)
const SELECTOR_APPROVE = "095ea7b3"; // approve(address,uint256)
const SELECTOR_TRANSFER_FROM = "23b872dd"; // transferFrom(address,address,uint256)

/**
 * Decode USDC amount from ERC-20 calldata.
 *
 * Supports transfer, approve, and transferFrom. Returns null for unknown
 * selectors - the contract allowlist is the primary guard for those.
 */
function decodeUsdcAmount(data: string): bigint | null {
  if (!data || data === "0x" || data.length < 10) return null;

  // Strip 0x prefix, normalize to lowercase
  const hex = data.startsWith("0x") ? data.slice(2).toLowerCase() : data.toLowerCase();
  const selector = hex.slice(0, 8);

  // transfer(address,uint256) / approve(address,uint256)
  // Layout: 4 selector + 32 address + 32 amount = 68 bytes = 136 hex chars
  if (selector === SELECTOR_TRANSFER || selector === SELECTOR_APPROVE) {
    if (hex.length < 136) return null;
    const amountHex = hex.slice(72, 136);
    return BigInt("0x" + amountHex);
  }

  // transferFrom(address,address,uint256)
  // Layout: 4 selector + 32 from + 32 to + 32 amount = 100 bytes = 200 hex chars
  if (selector === SELECTOR_TRANSFER_FROM) {
    if (hex.length < 200) return null;
    const amountHex = hex.slice(136, 200);
    return BigInt("0x" + amountHex);
  }

  return null;
}

// ── Rules ──────────────────────────────────────────────────────────────

/** Rule 1: Chain must be in the allowed set. */
function checkChain(ctx: PolicyContext): PolicyResult | null {
  const chainIds = ctx.policy_config?.chain_ids;
  if (!chainIds || chainIds.length === 0) return null; // No chain restriction configured

  if (!ctx.chain_id) {
    return deny("Missing chain_id in policy context");
  }

  if (!chainIds.includes(ctx.chain_id)) {
    return deny(
      `Chain ${ctx.chain_id} not in allowed chains: ${chainIds.join(", ")}`,
    );
  }
  return null;
}

/** Rule 2: Transaction target must be in the allowed contracts set. */
function checkContracts(ctx: PolicyContext): PolicyResult | null {
  const allowed = ctx.policy_config?.allowed_contracts;
  if (!allowed || allowed.length === 0) return null; // No contract restriction configured

  const to = ctx.transaction?.to;
  if (!to) {
    return deny("Transaction missing target address");
  }

  const toLower = to.toLowerCase();
  const allowedLower = allowed.map((a) => a.toLowerCase());

  if (!allowedLower.includes(toLower)) {
    return deny(`Transaction to ${to} not in allowed contracts`);
  }
  return null;
}

/** Rule 3: Single transaction USDC amount must not exceed cap. */
function checkPerTx(ctx: PolicyContext): PolicyResult | null {
  const maxTxUsdc = ctx.policy_config?.max_tx_usdc;
  if (maxTxUsdc === undefined || maxTxUsdc === null) return null; // No per-tx limit

  if (typeof maxTxUsdc !== "number" || maxTxUsdc < 0) {
    return deny("Invalid max_tx_usdc in policy config");
  }

  const amount = decodeUsdcAmount(ctx.transaction?.data ?? "");
  if (amount === null) return null; // Unknown selector - contract allowlist is the guard

  // USDC has 6 decimals: base units ÷ 1e6 = dollars
  const amountUsdc = Number(amount) / 1e6;

  if (amountUsdc > maxTxUsdc) {
    return deny(
      `Transaction amount $${amountUsdc.toFixed(2)} exceeds per-tx limit of $${maxTxUsdc}`,
    );
  }
  return null;
}

/** Rule 4: Cumulative daily USDC spending must not exceed cap. */
function checkDaily(ctx: PolicyContext): PolicyResult | null {
  const dailyLimit = ctx.policy_config?.daily_limit_usdc;
  if (dailyLimit === undefined || dailyLimit === null) return null; // No daily limit

  if (typeof dailyLimit !== "number" || dailyLimit < 0) {
    return deny("Invalid daily_limit_usdc in policy config");
  }

  let dailyTotal: bigint;
  try {
    dailyTotal = BigInt(ctx.spending?.daily_total ?? "0");
  } catch {
    return deny("Invalid spending.daily_total - not a valid integer");
  }

  const txAmount = decodeUsdcAmount(ctx.transaction?.data ?? "") ?? 0n;

  // Both in USDC base units (6 decimals)
  const projectedUsdc = Number(dailyTotal + txAmount) / 1e6;

  if (projectedUsdc > dailyLimit) {
    return deny(
      `Daily spending would reach $${projectedUsdc.toFixed(2)}, exceeding limit of $${dailyLimit}`,
    );
  }
  return null;
}

// ── Main ───────────────────────────────────────────────────────────────

const RULES = [checkChain, checkContracts, checkPerTx, checkDaily];

/** Exported for testing - evaluates all rules against the given context. */
export function evaluate(ctx: PolicyContext): PolicyResult {
  for (const rule of RULES) {
    const result = rule(ctx);
    if (result !== null) return result;
  }
  return ALLOW;
}

/** Exported for testing. */
export { decodeUsdcAmount, type PolicyContext, type PolicyConfig, type PolicyResult };

async function main(): Promise<void> {
  let ctx: PolicyContext;

  try {
    const raw = await readStdin();
    if (!raw.trim()) {
      process.stdout.write(JSON.stringify(deny("Empty input")) + "\n");
      process.exit(0);
    }
    ctx = JSON.parse(raw) as PolicyContext;
  } catch {
    process.stdout.write(
      JSON.stringify(deny("Failed to parse policy context")) + "\n",
    );
    process.exit(0);
  }

  const result = evaluate(ctx);
  process.stdout.write(JSON.stringify(result) + "\n");
  process.exit(0);
}

// Only run main when executed directly (not when imported for testing).
const isDirectRun =
  process.argv[1] &&
  (process.argv[1].endsWith("remit-policy.js") ||
    process.argv[1].endsWith("remit-policy.ts"));

if (isDirectRun) {
  main().catch(() => {
    process.stdout.write(
      JSON.stringify(deny("Internal policy error")) + "\n",
    );
    process.exit(1);
  });
}
