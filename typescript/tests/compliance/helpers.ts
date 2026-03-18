/**
 * Compliance test helpers: register operators, create funded Wallet instances.
 *
 * Environment variables (set by CI; defaults match docker-compose.compliance.yml):
 *   REMIT_TEST_SERVER_URL   Server base URL (default: http://localhost:3000)
 *   REMIT_ROUTER_ADDRESS    Router contract address for EIP-712 domain
 *   REMIT_CHAIN_ID          Chain ID for EIP-712 domain (default: 84532)
 */

import { Wallet } from "../../src/wallet.js";

export const SERVER_URL =
  process.env["REMIT_TEST_SERVER_URL"] ?? "http://localhost:3000";
export const ROUTER_ADDRESS =
  process.env["REMIT_ROUTER_ADDRESS"] ??
  "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
export const CHAIN_ID = Number(process.env["REMIT_CHAIN_ID"] ?? "84532");

/** Returns true if the compliance server is reachable and healthy. */
export async function serverIsReachable(): Promise<boolean> {
  try {
    const resp = await fetch(`${SERVER_URL}/health`, { signal: AbortSignal.timeout(3000) });
    return resp.ok;
  } catch {
    return false;
  }
}

/** Register a new operator and return (privateKey, walletAddress). */
export async function registerAndGetWallet(): Promise<{
  privateKey: string;
  walletAddress: string;
}> {
  const email = `compliance.ts.${Date.now()}@test.remitmd.local`;
  const password = "ComplianceTestPass1!";

  const regResp = await fetch(`${SERVER_URL}/api/v0/auth/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  if (!regResp.ok) {
    throw new Error(`register failed: ${regResp.status} ${await regResp.text()}`);
  }
  const reg = (await regResp.json()) as { token: string; wallet_address: string };

  const keyResp = await fetch(`${SERVER_URL}/api/v0/auth/agent-key`, {
    headers: { Authorization: `Bearer ${reg.token}` },
  });
  if (!keyResp.ok) {
    throw new Error(`agent-key failed: ${keyResp.status} ${await keyResp.text()}`);
  }
  const keyData = (await keyResp.json()) as { private_key: string };

  return { privateKey: keyData.private_key, walletAddress: reg.wallet_address };
}

/** Create a Wallet backed by a freshly registered operator. */
export async function makeWallet(): Promise<Wallet> {
  const { privateKey } = await registerAndGetWallet();
  return new Wallet({
    privateKey,
    chain: "base-sepolia",
    apiUrl: `${SERVER_URL}/api/v0`,
    routerAddress: ROUTER_ADDRESS,
  });
}

/** Create two wallets (payer + payee) and fund the payer via mint. */
export async function makeFundedPair(): Promise<{
  payer: Wallet;
  payee: Wallet;
  payeeAddress: string;
}> {
  const { privateKey: pkA } = await registerAndGetWallet();
  const { privateKey: pkB, walletAddress: addrB } = await registerAndGetWallet();

  const walletOpts = {
    chain: "base-sepolia" as const,
    apiUrl: `${SERVER_URL}/api/v0`,
    routerAddress: ROUTER_ADDRESS,
  };

  const payer = new Wallet({ privateKey: pkA, ...walletOpts });
  const payee = new Wallet({ privateKey: pkB, ...walletOpts });

  await payer.mint(100);

  return { payer, payee, payeeAddress: addrB };
}
