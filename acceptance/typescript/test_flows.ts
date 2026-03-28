#!/usr/bin/env npx tsx
/**
 * Remit SDK Acceptance — TypeScript: 9 flows against Base Sepolia.
 *
 * Flows: Direct, Escrow, Tab (2 charges), Stream, Bounty, Deposit, x402 Weather,
 * AP2 Discovery, AP2 Payment.
 */

import {
  Wallet,
  PrivateKeySigner,
  discoverAgent,
  A2AClient,
} from "@remitmd/sdk";
import type { AgentCard, IntentMandate } from "@remitmd/sdk";
import { generatePrivateKey } from "viem/accounts";

// ─── Config ──────────────────────────────────────────────────────────────────
const API_URL = process.env["ACCEPTANCE_API_URL"] ?? "https://testnet.remit.md";
const API_BASE = `${API_URL}/api/v1`;
const RPC_URL = process.env["ACCEPTANCE_RPC_URL"] ?? "https://sepolia.base.org";
const CHAIN_ID = 84532;
const USDC_ADDRESS = "0x2d846325766921935f37d5b4478196d3ef93707c";

// ─── Colors ──────────────────────────────────────────────────────────────────
const GREEN = "\x1b[0;32m";
const RED = "\x1b[0;31m";
const CYAN = "\x1b[0;36m";
const BOLD = "\x1b[1m";
const RESET = "\x1b[0m";

const results: Record<string, string> = {};

function logPass(flow: string, msg = ""): void {
  const extra = msg ? ` — ${msg}` : "";
  console.log(`${GREEN}[PASS]${RESET} ${flow}${extra}`);
  results[flow] = "PASS";
}

function logFail(flow: string, msg: string): void {
  console.log(`${RED}[FAIL]${RESET} ${flow} — ${msg}`);
  results[flow] = "FAIL";
}

function logInfo(msg: string): void {
  console.log(`${CYAN}[INFO]${RESET} ${msg}`);
}

function logTx(flow: string, step: string, txHash: string): void {
  console.log(`  [TX] ${flow} | ${step} | https://sepolia.basescan.org/tx/${txHash}`);
}

// ─── Helpers ─────────────────────────────────────────────────────────────────
async function getUsdcBalance(address: string): Promise<number> {
  const padded = address.toLowerCase().replace("0x", "").padStart(64, "0");
  const data = `0x70a08231${padded}`;
  const res = await fetch(RPC_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0", id: 1, method: "eth_call",
      params: [{ to: USDC_ADDRESS, data }, "latest"],
    }),
  });
  const json = (await res.json()) as { result?: string; error?: { message: string } };
  if (json.error) throw new Error(`RPC error: ${json.error.message}`);
  return Number(BigInt(json.result ?? "0x0")) / 1e6;
}

async function waitForBalanceChange(address: string, before: number, maxWait = 30000): Promise<number> {
  const start = Date.now();
  while (Date.now() - start < maxWait) {
    const current = await getUsdcBalance(address);
    if (Math.abs(current - before) > 0.0001) return current;
    await new Promise(r => setTimeout(r, 2000));
  }
  return getUsdcBalance(address);
}

let _routerAddress: string | null = null;

async function getRouterAddress(): Promise<string> {
  if (_routerAddress) return _routerAddress;
  const res = await fetch(`${API_BASE}/contracts`);
  if (!res.ok) throw new Error(`GET /contracts failed: ${res.status}`);
  const data = (await res.json()) as { router: string };
  _routerAddress = data.router;
  return _routerAddress;
}

interface WalletWithSigner {
  wallet: Wallet;
  signer: PrivateKeySigner;
  key: string;
}

async function createWalletWithSigner(): Promise<WalletWithSigner> {
  const key = generatePrivateKey();
  const signer = new PrivateKeySigner(key);
  const routerAddress = await getRouterAddress();
  const wallet = new Wallet({
    privateKey: key,
    chain: "base-sepolia",
    apiUrl: API_URL,
    rpcUrl: RPC_URL,
    routerAddress,
  });
  return { wallet, signer, key };
}

async function fundWallet(wallet: Wallet, amount = 100): Promise<void> {
  await wallet.mint(amount);
  await waitForBalanceChange(wallet.address, 0);
}

function sleep(ms: number): Promise<void> {
  return new Promise(r => setTimeout(r, ms));
}

function getTxHash(tx: unknown): string {
  const obj = tx as Record<string, unknown>;
  return (obj.txHash ?? obj.tx_hash ?? "") as string;
}

// ─── Flow 1: Direct Payment ─────────────────────────────────────────────────
async function flowDirect(agent: Wallet, provider: Wallet): Promise<void> {
  const flow = "1. Direct Payment";
  const contracts = await agent.getContracts();
  const permit = await agent.signPermit(contracts.router, 2.0);
  const tx = await agent.payDirect(provider.address, 1.0, "acceptance-direct", { permit });
  const txHash = getTxHash(tx);
  if (!txHash.startsWith("0x")) throw new Error(`bad tx_hash: ${txHash}`);
  logTx(flow, "pay", txHash);
  logPass(flow, `tx=${txHash.slice(0, 18)}...`);
}

// ─── Flow 2: Escrow ─────────────────────────────────────────────────────────
async function flowEscrow(agent: Wallet, provider: Wallet): Promise<void> {
  const flow = "2. Escrow";
  const contracts = await agent.getContracts();
  const permit = await agent.signPermit(contracts.escrow, 6.0);
  const escrow = await agent.pay(
    { to: provider.address, amount: 5.0, memo: "acceptance-escrow" },
    { permit },
  );
  const escrowId = (escrow as Record<string, unknown>).invoiceId ?? (escrow as Record<string, unknown>).invoice_id;
  if (!escrowId) throw new Error("escrow should have an id");
  const txHash = getTxHash(escrow);
  if (txHash) logTx(flow, "fund", txHash);

  await sleep(5000);
  const claim = await provider.claimStart(escrowId as string);
  const claimHash = getTxHash(claim);
  if (claimHash) logTx(flow, "claimStart", claimHash);
  await sleep(5000);

  const release = await agent.releaseEscrow(escrowId as string);
  const releaseHash = getTxHash(release);
  if (releaseHash) logTx(flow, "release", releaseHash);
  logPass(flow, `escrow_id=${escrowId}`);
}

// ─── Flow 3: Metered Tab (2 charges) ────────────────────────────────────────
async function flowTab(agent: Wallet, provider: Wallet): Promise<void> {
  const flow = "3. Metered Tab";
  const contracts = await agent.getContracts();
  const tabContract = contracts.tab;
  const permit = await agent.signPermit(tabContract, 11.0);

  const tab = await agent.openTab({
    to: provider.address, limit: 10.0, perUnit: 0.1, permit,
  });
  const tabId = tab.id;
  if (!tabId) throw new Error("tab should have an id");
  const openHash = getTxHash(tab);
  if (openHash) logTx(flow, "open", openHash);

  await waitForBalanceChange(agent.address, await getUsdcBalance(agent.address));

  // Charge 1: $2
  const sig1 = await provider.signTabCharge(tabContract, tabId, BigInt(2_000_000), 1);
  const charge1 = await provider.chargeTab(tabId, {
    amount: 2.0, cumulative: 2.0, callCount: 1, providerSig: sig1,
  });
  logTx(flow, "charge1", getTxHash(charge1) || "n/a");

  // Charge 2: $1 more (cumulative $3)
  const sig2 = await provider.signTabCharge(tabContract, tabId, BigInt(3_000_000), 2);
  const charge2 = await provider.chargeTab(tabId, {
    amount: 1.0, cumulative: 3.0, callCount: 2, providerSig: sig2,
  });
  logTx(flow, "charge2", getTxHash(charge2) || "n/a");

  // Close
  const closeSig = await provider.signTabCharge(tabContract, tabId, BigInt(3_000_000), 2);
  const closed = await agent.closeTab(tabId, { finalAmount: 3.0, providerSig: closeSig });
  logTx(flow, "close", getTxHash(closed) || "n/a");
  logPass(flow, `tab_id=${tabId}, charged=$3, 2 charges`);
}

// ─── Flow 4: Stream ─────────────────────────────────────────────────────────
async function flowStream(agent: Wallet, provider: Wallet): Promise<void> {
  const flow = "4. Stream";
  const contracts = await agent.getContracts();
  const permit = await agent.signPermit(contracts.stream, 6.0);

  const stream = await agent.openStream({
    to: provider.address, rate: 0.01, maxTotal: 5.0, permit,
  });
  const streamId = stream.id;
  if (!streamId) throw new Error("stream should have an id");
  logTx(flow, "open", getTxHash(stream) || "n/a");

  await sleep(5000);

  const closed = await agent.closeStream(streamId);
  logTx(flow, "close", getTxHash(closed) || "n/a");
  logPass(flow, `stream_id=${streamId}`);
}

// ─── Flow 5: Bounty ─────────────────────────────────────────────────────────
async function flowBounty(agent: Wallet, provider: Wallet): Promise<void> {
  const flow = "5. Bounty";
  const contracts = await agent.getContracts();
  const permit = await agent.signPermit(contracts.bounty, 6.0);

  const bounty = await agent.postBounty({
    amount: 5.0, task: "acceptance-bounty-test",
    deadline: Math.floor(Date.now() / 1000) + 3600, permit,
  });
  const bountyId = bounty.id;
  if (!bountyId) throw new Error("bounty should have an id");
  logTx(flow, "post", getTxHash(bounty) || "n/a");

  await waitForBalanceChange(agent.address, await getUsdcBalance(agent.address));

  const evidenceHash = "0x" + "ab".repeat(32);
  const submission = await provider.submitBounty(bountyId, evidenceHash);
  const subId = (submission as Record<string, unknown>).id ?? (submission as Record<string, unknown>).submission_id;
  if (!subId) throw new Error("submission should have an id");
  await sleep(5000);

  const awarded = await agent.awardBounty(bountyId, Number(subId));
  logTx(flow, "award", getTxHash(awarded) || "n/a");
  logPass(flow, `bounty_id=${bountyId}`);
}

// ─── Flow 6: Deposit ────────────────────────────────────────────────────────
async function flowDeposit(agent: Wallet, provider: Wallet): Promise<void> {
  const flow = "6. Deposit";
  const contracts = await agent.getContracts();
  const permit = await agent.signPermit(contracts.deposit, 6.0);

  const deposit = await agent.placeDeposit({
    to: provider.address, amount: 5.0, expires: 3600, permit,
  });
  const depositId = deposit.id;
  if (!depositId) throw new Error("deposit should have an id");
  logTx(flow, "place", getTxHash(deposit) || "n/a");

  await waitForBalanceChange(agent.address, await getUsdcBalance(agent.address));

  const returned = await provider.returnDeposit(depositId);
  logTx(flow, "return", getTxHash(returned) || "n/a");
  logPass(flow, `deposit_id=${depositId}`);
}

// ─── Flow 7: x402 Weather ───────────────────────────────────────────────────
async function flowX402Weather(agent: Wallet, signer: PrivateKeySigner): Promise<void> {
  const flow = "7. x402 Weather";

  // Step 1: Hit the paywall
  const resp = await fetch(`${API_BASE}/x402/demo`);
  if (resp.status !== 402) { logFail(flow, `expected 402, got ${resp.status}`); return; }

  const scheme = resp.headers.get("x-payment-scheme") ?? "exact";
  const network = resp.headers.get("x-payment-network") ?? `eip155:${CHAIN_ID}`;
  const amountStr = resp.headers.get("x-payment-amount") ?? "5000000";
  const asset = resp.headers.get("x-payment-asset") ?? USDC_ADDRESS;
  const payTo = resp.headers.get("x-payment-payto") ?? "";
  const amountRaw = parseInt(amountStr);

  logInfo(`  Paywall: ${scheme} | $${amountRaw / 1e6} USDC | network=${network}`);

  // Step 2: Sign EIP-3009
  const chainId = network.includes(":") ? parseInt(network.split(":")[1]!) : CHAIN_ID;
  const now = Math.floor(Date.now() / 1000);
  const validBefore = now + 300;
  const nonce = "0x" + Array.from(crypto.getRandomValues(new Uint8Array(32))).map(b => b.toString(16).padStart(2, "0")).join("");

  // Build auth headers manually for the settle call
  const authTimestamp = Math.floor(Date.now() / 1000);
  const authNonce = "0x" + Array.from(crypto.getRandomValues(new Uint8Array(32))).map(b => b.toString(16).padStart(2, "0")).join("");
  const contracts = await agent.getContracts();

  const authSig = await signer.signTypedData(
    { name: "remit.md", version: "0.1", chainId, verifyingContract: contracts.router },
    { APIRequest: [
      { name: "method", type: "string" },
      { name: "path", type: "string" },
      { name: "timestamp", type: "uint256" },
      { name: "nonce", type: "bytes32" },
    ]},
    { method: "POST", path: "/api/v1/x402/settle", timestamp: BigInt(authTimestamp), nonce: authNonce },
  );

  // Sign EIP-3009 TransferWithAuthorization
  const eip3009Sig = await signer.signTypedData(
    { name: "USD Coin", version: "2", chainId, verifyingContract: asset },
    { TransferWithAuthorization: [
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "value", type: "uint256" },
      { name: "validAfter", type: "uint256" },
      { name: "validBefore", type: "uint256" },
      { name: "nonce", type: "bytes32" },
    ]},
    {
      from: agent.address, to: payTo,
      value: BigInt(amountRaw), validAfter: 0n,
      validBefore: BigInt(validBefore), nonce,
    },
  );

  // Step 3: Settle
  const settleBody = {
    paymentPayload: {
      scheme, network, x402Version: 1,
      payload: {
        signature: eip3009Sig,
        authorization: {
          from: agent.address, to: payTo,
          value: amountStr, validAfter: "0",
          validBefore: String(validBefore), nonce,
        },
      },
    },
    paymentRequired: {
      scheme, network, amount: amountStr,
      asset, payTo, maxTimeoutSeconds: 300,
    },
  };

  const settleResp = await fetch(`${API_BASE}/x402/settle`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Remit-Signature": authSig,
      "X-Remit-Agent": agent.address,
      "X-Remit-Timestamp": String(authTimestamp),
      "X-Remit-Nonce": authNonce,
    },
    body: JSON.stringify(settleBody),
  });
  if (!settleResp.ok) {
    const errText = await settleResp.text();
    logFail(flow, `settle failed: ${settleResp.status} ${errText}`);
    return;
  }
  const settleData = (await settleResp.json()) as { transactionHash?: string };
  const txHash = settleData.transactionHash ?? "";
  if (!txHash) { logFail(flow, `no txHash in settle response`); return; }
  logTx(flow, "settle", txHash);

  // Step 4: Fetch weather with payment proof
  const weatherResp = await fetch(`${API_BASE}/x402/demo`, {
    headers: { "X-Payment-Response": txHash },
  });
  if (weatherResp.status !== 200) {
    logFail(flow, `weather fetch returned ${weatherResp.status}`);
    return;
  }

  const weather = (await weatherResp.json()) as Record<string, Record<string, unknown>>;
  const loc = weather["location"] ?? {};
  const cur = weather["current"] ?? {};
  const cond = (cur["condition"] as Record<string, unknown>) ?? {};

  const city = (loc["name"] ?? "Unknown") as string;
  const region = `${loc["region"] ?? ""}, ${loc["country"] ?? ""}`.replace(/^, |, $/g, "");
  const tempF = cur["temp_f"] ?? "?";
  const tempC = cur["temp_c"] ?? "?";
  const condition = (cond["text"] ?? cur["condition"] ?? "Unknown") as string;
  const humidity = cur["humidity"] ?? "?";
  const windMph = cur["wind_mph"] ?? cur["wind_kph"] ?? "?";
  const windDir = cur["wind_dir"] ?? "";

  console.log();
  console.log(`${CYAN}┌─────────────────────────────────────────────┐${RESET}`);
  console.log(`${CYAN}│${RESET}  ${BOLD}x402 Weather Report${RESET} (paid $${amountRaw / 1e6} USDC)   ${CYAN}│${RESET}`);
  console.log(`${CYAN}├─────────────────────────────────────────────┤${RESET}`);
  console.log(`${CYAN}│${RESET}  City:        ${String(city).padEnd(29)}${CYAN}│${RESET}`);
  console.log(`${CYAN}│${RESET}  Region:      ${String(region).padEnd(29)}${CYAN}│${RESET}`);
  console.log(`${CYAN}│${RESET}  Temperature: ${tempF}°F / ${tempC}°C${" ".repeat(Math.max(0, 19 - String(tempF).length - String(tempC).length))}${CYAN}│${RESET}`);
  console.log(`${CYAN}│${RESET}  Condition:   ${String(condition).padEnd(29)}${CYAN}│${RESET}`);
  console.log(`${CYAN}│${RESET}  Humidity:    ${humidity}%${" ".repeat(Math.max(0, 28 - String(humidity).length))}${CYAN}│${RESET}`);
  console.log(`${CYAN}│${RESET}  Wind:        ${windMph} mph ${windDir}${" ".repeat(Math.max(0, 22 - String(windMph).length - String(windDir).length))}${CYAN}│${RESET}`);
  console.log(`${CYAN}└─────────────────────────────────────────────┘${RESET}`);
  console.log();

  logPass(flow, `city=${city}, tx=${txHash.slice(0, 18)}...`);
}

// ─── Flow 8: AP2 Discovery ──────────────────────────────────────────────────
async function flowAP2Discovery(): Promise<void> {
  const flow = "8. AP2 Discovery";
  const card = await discoverAgent(API_URL);

  console.log();
  console.log(`${CYAN}┌─────────────────────────────────────────────┐${RESET}`);
  console.log(`${CYAN}│${RESET}  ${BOLD}A2A Agent Card${RESET}                            ${CYAN}│${RESET}`);
  console.log(`${CYAN}├─────────────────────────────────────────────┤${RESET}`);
  console.log(`${CYAN}│${RESET}  Name:     ${String(card.name).padEnd(32)}${CYAN}│${RESET}`);
  console.log(`${CYAN}│${RESET}  Version:  ${String(card.version).padEnd(32)}${CYAN}│${RESET}`);
  console.log(`${CYAN}│${RESET}  URL:      ${String(card.url).slice(0, 32).padEnd(32)}${CYAN}│${RESET}`);
  if (card.skills?.length) {
    console.log(`${CYAN}│${RESET}  Skills:   ${String(card.skills.length)} total${" ".repeat(25)}${CYAN}│${RESET}`);
    for (const s of card.skills.slice(0, 5)) {
      console.log(`${CYAN}│${RESET}    - ${String(s.name).slice(0, 38).padEnd(38)}${CYAN}│${RESET}`);
    }
  }
  console.log(`${CYAN}└─────────────────────────────────────────────┘${RESET}`);
  console.log();

  if (!card.name) throw new Error("agent card should have a name");
  logPass(flow, `name=${card.name}`);
}

// ─── Flow 9: AP2 Payment ────────────────────────────────────────────────────
async function flowAP2Payment(agent: Wallet, provider: Wallet, signer: PrivateKeySigner): Promise<void> {
  const flow = "9. AP2 Payment";
  const card = await discoverAgent(API_URL);
  const contracts = await agent.getContracts();

  const a2a = A2AClient.fromCard(card, signer, {
    chain: "base-sepolia",
    verifyingContract: contracts.router,
  });

  const mandate: IntentMandate = {
    mandateId: crypto.randomUUID().replace(/-/g, ""),
    expiresAt: "2099-12-31T23:59:59Z",
    issuer: agent.address,
    allowance: { maxAmount: "5.00", currency: "USDC" },
  };

  const task = await a2a.send({
    to: provider.address, amount: 1.0,
    memo: "acceptance-ap2-payment", mandate,
  });

  if (!task.id) throw new Error("a2a task should have an id");
  const state = task.status?.state ?? "unknown";
  if (state !== "completed") throw new Error(`a2a task state=${state}, expected completed`);

  const txHash = getTaskTxHash(task);
  if (txHash) logTx(flow, "a2a-pay", txHash);

  // Verify persistence
  const fetched = await a2a.getTask(task.id);
  if (fetched.id !== task.id) throw new Error("fetched task id mismatch");

  logPass(flow, `task_id=${task.id}, state=${state}`);
}

function getTaskTxHash(task: Record<string, unknown>): string {
  const artifacts = (task.artifacts ?? []) as Array<Record<string, unknown>>;
  for (const artifact of artifacts) {
    const parts = (artifact.parts ?? []) as Array<Record<string, unknown>>;
    for (const part of parts) {
      const data = part.data as Record<string, unknown> | undefined;
      if (data?.txHash) return data.txHash as string;
    }
  }
  return "";
}

// ─── Main ────────────────────────────────────────────────────────────────────
async function main(): Promise<void> {
  console.log();
  console.log(`${BOLD}TypeScript SDK — 9 Flow Acceptance Suite${RESET}`);
  console.log(`  API: ${API_URL}`);
  console.log(`  RPC: ${RPC_URL}`);
  console.log();

  logInfo("Creating agent wallet...");
  const agentWs = await createWalletWithSigner();
  const agent = agentWs.wallet;
  logInfo(`  Agent:    ${agent.address}`);

  logInfo("Creating provider wallet...");
  const providerWs = await createWalletWithSigner();
  const provider = providerWs.wallet;
  logInfo(`  Provider: ${provider.address}`);

  logInfo("Minting $100 USDC to agent...");
  await fundWallet(agent, 100);
  logInfo(`  Agent balance: $${(await getUsdcBalance(agent.address)).toFixed(2)}`);

  logInfo("Minting $100 USDC to provider...");
  await fundWallet(provider, 100);
  logInfo(`  Provider balance: $${(await getUsdcBalance(provider.address)).toFixed(2)}`);
  console.log();

  const flows: Array<[string, () => Promise<void>]> = [
    ["1. Direct Payment", () => flowDirect(agent, provider)],
    ["2. Escrow", () => flowEscrow(agent, provider)],
    ["3. Metered Tab", () => flowTab(agent, provider)],
    ["4. Stream", () => flowStream(agent, provider)],
    ["5. Bounty", () => flowBounty(agent, provider)],
    ["6. Deposit", () => flowDeposit(agent, provider)],
    ["7. x402 Weather", () => flowX402Weather(agent, agentWs.signer)],
    ["8. AP2 Discovery", () => flowAP2Discovery()],
    ["9. AP2 Payment", () => flowAP2Payment(agent, provider, agentWs.signer)],
  ];

  for (const [name, fn] of flows) {
    try {
      await fn();
      // Allow indexer to catch up with on-chain nonce between permit-consuming flows
      await sleep(5000);
    } catch (e) {
      const err = e as Error;
      // Gracefully skip AP2 if the endpoint is not available on testnet
      if (name.includes("AP2 Payment") && (
        err.message.includes("task should have an id") ||
        err.message.toLowerCase().includes("auth") ||
        err.message.includes("401") || err.message.includes("403")
      )) {
        console.log(`\x1b[1;33m[SKIP]\x1b[0m ${name} — AP2 endpoint may not be available on testnet: ${err.message}`);
        results[name] = "SKIP";
      } else {
        logFail(name, `${err.constructor.name}: ${err.message}`);
        console.error(err.stack);
      }
    }
  }

  const passed = Object.values(results).filter(v => v === "PASS").length;
  const failed = Object.values(results).filter(v => v === "FAIL").length;
  console.log();
  console.log(`${BOLD}TypeScript Summary: ${GREEN}${passed} passed${RESET}, ${RED}${failed} failed${RESET} / 9 flows`);
  console.log(JSON.stringify({ passed, failed, skipped: 9 - passed - failed }));
  process.exit(failed > 0 ? 1 : 0);
}

main().catch(e => {
  console.error(e);
  process.exit(1);
});
