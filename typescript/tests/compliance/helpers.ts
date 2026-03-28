/**
 * Compliance test helpers: register operators, create funded Wallet instances.
 *
 * Environment variables (set by CI; defaults match docker-compose.compliance.yml):
 *   REMIT_TEST_SERVER_URL   Server base URL (default: http://localhost:3000)
 *   REMIT_ROUTER_ADDRESS    Router contract address for EIP-712 domain
 *   REMIT_CHAIN_ID          Chain ID for EIP-712 domain (default: 84532)
 */

import crypto from "node:crypto";

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

/** Generate a random private key and derive the wallet address. */
export function generateWallet(): {
  privateKey: string;
  walletAddress: string;
} {
  const privateKey = "0x" + crypto.randomBytes(32).toString("hex");
  const wallet = new Wallet({
    privateKey,
    chain: "base-sepolia",
    apiUrl: `${SERVER_URL}/api/v1`,
    routerAddress: ROUTER_ADDRESS,
  });
  console.log(`[COMPLIANCE] wallet generated: ${wallet.address} (chain=${CHAIN_ID})`);
  return { privateKey, walletAddress: wallet.address };
}

/** Create a Wallet backed by a random keypair. */
export function makeWallet(): Wallet {
  const { privateKey } = generateWallet();
  return new Wallet({
    privateKey,
    chain: "base-sepolia",
    apiUrl: `${SERVER_URL}/api/v1`,
    routerAddress: ROUTER_ADDRESS,
  });
}

/** Create two wallets (payer + payee) and fund the payer via mint. */
export async function makeFundedPair(): Promise<{
  payer: Wallet;
  payee: Wallet;
  payeeAddress: string;
}> {
  const { privateKey: pkA } = generateWallet();
  const { privateKey: pkB, walletAddress: addrB } = generateWallet();

  const walletOpts = {
    chain: "base-sepolia" as const,
    apiUrl: `${SERVER_URL}/api/v1`,
    routerAddress: ROUTER_ADDRESS,
  };

  const payer = new Wallet({ privateKey: pkA, ...walletOpts });
  const payee = new Wallet({ privateKey: pkB, ...walletOpts });

  console.log(`[COMPLIANCE] funded pair: payer=${payer.address} payee=${payee.address}`);
  const mintResult = await payer.mint(100);
  console.log(`[COMPLIANCE] mint: 100 USDC -> ${payer.address} tx=${mintResult.tx_hash}`);

  return { payer, payee, payeeAddress: addrB };
}
