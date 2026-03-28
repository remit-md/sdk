/**
 * SDK acceptance test harness.
 *
 * Uses SDK Wallet to interact with the live Base Sepolia API.
 * No raw HTTP - everything goes through SDK methods.
 */

import { Wallet } from "../../src/wallet.js";
import { generatePrivateKey } from "viem/accounts";

// ─── Config ──────────────────────────────────────────────────────────────────

export const API_URL = process.env["ACCEPTANCE_API_URL"] ?? "https://testnet.remit.md/api/v1";
export const RPC_URL = process.env["ACCEPTANCE_RPC_URL"] ?? "https://sepolia.base.org";

// ─── Contract addresses (fetched once from /contracts) ──────────────────────

let _contracts: Record<string, string> | null = null;

async function getContracts(): Promise<Record<string, string>> {
  if (_contracts) return _contracts;
  const res = await fetch(`${API_URL}/contracts`);
  if (!res.ok) throw new Error(`GET /contracts failed: ${res.status}`);
  _contracts = (await res.json()) as Record<string, string>;
  return _contracts;
}

// ─── Wallet creation ────────────────────────────────────────────────────────

export async function createWallet(): Promise<Wallet> {
  const key = generatePrivateKey();
  const contracts = await getContracts();
  return new Wallet({
    privateKey: key,
    chain: "base-sepolia",
    apiUrl: API_URL,
    rpcUrl: RPC_URL,
    routerAddress: contracts.router,
  });
}

// ─── Funding ────────────────────────────────────────────────────────────────

/** Mint testnet USDC and wait for on-chain confirmation. */
export async function fundWallet(wallet: Wallet, amount = 100): Promise<void> {
  await wallet.mint(amount);
  // Wait for balance via RPC (doesn't require auth)
  await waitForBalanceChange(wallet.address, 0);
}

// ─── On-chain balance via RPC ───────────────────────────────────────────────

/** Read USDC balance via RPC eth_call to balanceOf(address). Returns USD. */
export async function getUsdcBalance(address: string): Promise<number> {
  const contracts = await getContracts();
  const paddedAddr = address.toLowerCase().replace("0x", "").padStart(64, "0");
  const data = `0x70a08231${paddedAddr}`;

  const res = await fetch(RPC_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "eth_call",
      params: [{ to: contracts.usdc, data }, "latest"],
    }),
  });
  const json = (await res.json()) as { result?: string; error?: { message: string } };
  if (json.error) throw new Error(`RPC balanceOf error: ${json.error.message}`);
  return Number(BigInt(json.result ?? "0x0")) / 1e6;
}

/** Wait for a balance change (polls every 2s, up to maxWait). */
export async function waitForBalanceChange(
  address: string,
  beforeBalance: number,
  maxWaitMs = 30000,
): Promise<number> {
  const start = Date.now();
  while (Date.now() - start < maxWaitMs) {
    const current = await getUsdcBalance(address);
    if (Math.abs(current - beforeBalance) > 0.0001) return current;
    await new Promise((r) => setTimeout(r, 2000));
  }
  return getUsdcBalance(address);
}

/** Assert a balance changed by expected delta within tolerance. */
export function assertBalanceChange(
  label: string,
  before: number,
  after: number,
  expectedDelta: number,
  toleranceBps = 10,
): void {
  const actualDelta = after - before;
  const tolerance = Math.abs(expectedDelta) * (toleranceBps / 10000);
  const diff = Math.abs(actualDelta - expectedDelta);

  if (diff > tolerance) {
    throw new Error(
      `${label}: expected delta ${expectedDelta}, got ${actualDelta} ` +
      `(before=${before}, after=${after}, tolerance=${tolerance})`,
    );
  }
}


/** Log a transaction hash with a basescan link. */
export function logTx(flow: string, step: string, txHash: string): void {
  console.log(`[TX] ${flow} | ${step} | ${txHash} | https://sepolia.basescan.org/tx/${txHash}`);
}
