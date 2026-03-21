/**
 * SDK acceptance test harness.
 *
 * Uses SDK Wallet to interact with the live Base Sepolia API.
 * No raw HTTP — everything goes through SDK methods.
 */

import { Wallet } from "../../src/wallet.js";
import { generatePrivateKey } from "viem/accounts";

// ─── Config ──────────────────────────────────────────────────────────────────

export const API_URL = process.env["ACCEPTANCE_API_URL"] ?? "https://remit.md/api/v1";
export const RPC_URL = process.env["ACCEPTANCE_RPC_URL"] ?? "https://sepolia.base.org";
export const FEE_WALLET = "0xd3f721BDF92a2bB5Dd8d2FE2AFC03aFE5629B420";

// ─── Router address (fetched once from /contracts) ──────────────────────────

let _routerAddress: string | null = null;

async function getRouterAddress(): Promise<string> {
  if (_routerAddress) return _routerAddress;
  const res = await fetch(`${API_URL}/contracts`);
  if (!res.ok) throw new Error(`GET /contracts failed: ${res.status}`);
  const data = (await res.json()) as { router: string };
  _routerAddress = data.router;
  return _routerAddress;
}

// ─── Wallet creation ────────────────────────────────────────────────────────

export async function createWallet(): Promise<Wallet> {
  const key = generatePrivateKey();
  const routerAddress = await getRouterAddress();
  return new Wallet({
    privateKey: key,
    chain: "base-sepolia",
    apiUrl: API_URL,
    rpcUrl: RPC_URL,
    routerAddress,
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
  const paddedAddr = address.toLowerCase().replace("0x", "").padStart(64, "0");
  const data = `0x70a08231${paddedAddr}`;
  const usdcAddress = "0x142aD61B8d2edD6b3807D9266866D97C35Ee0317";

  const res = await fetch(RPC_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "eth_call",
      params: [{ to: usdcAddress, data }, "latest"],
    }),
  });
  const json = (await res.json()) as { result?: string; error?: { message: string } };
  if (json.error) throw new Error(`RPC balanceOf error: ${json.error.message}`);
  return Number(BigInt(json.result ?? "0x0")) / 1e6;
}

export async function getFeeWalletBalance(): Promise<number> {
  return getUsdcBalance(FEE_WALLET);
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

/** Assert fee wallet balance increased (shared fee wallet, "at least" pattern). */
export function assertFeeIncrease(
  label: string,
  before: number,
  after: number,
  minExpected: number,
): void {
  const delta = after - before;
  if (delta < minExpected - 0.001) {
    throw new Error(
      `${label}: fee wallet should have increased by at least ${minExpected}, ` +
      `got delta=${delta} (before=${before}, after=${after})`,
    );
  }
}

/** Log a transaction hash with a basescan link. */
export function logTx(flow: string, step: string, txHash: string): void {
  console.log(`[TX] ${flow} | ${step} | ${txHash} | https://sepolia.basescan.org/tx/${txHash}`);
}
