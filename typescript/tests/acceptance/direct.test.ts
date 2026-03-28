/**
 * SDK acceptance: Direct payment via wallet.payDirect().
 * Verifies SDK permit signing + payment works end-to-end.
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import type { Wallet } from "../../src/wallet.js";
import {
  createWallet,
  fundWallet,
  getUsdcBalance,
  assertBalanceChange,
  waitForBalanceChange,
  logTx,
} from "./setup.js";

describe("SDK: Direct Payment", { timeout: 120_000 }, () => {
  let agent: Wallet;
  let provider: Wallet;

  before(async () => {
    agent = await createWallet();
    provider = await createWallet();
    await fundWallet(agent, 100);
  });

  it("payDirect with signPermit - correct balances", async () => {
    const amount = 1.0;
    const fee = 0.01;
    const providerReceives = amount - fee;

    const agentBefore = await getUsdcBalance(agent.address);
    const providerBefore = await getUsdcBalance(provider.address);
    // SDK: get contracts, sign permit, pay
    const contracts = await agent.getContracts();
    const permit = await agent.signPermit(contracts.router, 2.0);
    const tx = await agent.payDirect(provider.address, amount, "sdk-acceptance", { permit });

    const txHash = tx.txHash ?? (tx as unknown as Record<string, string>).tx_hash;
    assert.ok(txHash?.startsWith("0x"), `should return tx hash, got: ${txHash}`);
    logTx("direct", "pay", txHash);

    const agentAfter = await waitForBalanceChange(agent.address, agentBefore);
    const providerAfter = await getUsdcBalance(provider.address);

    assertBalanceChange("agent", agentBefore, agentAfter, -amount);
    assertBalanceChange("provider", providerBefore, providerAfter, providerReceives);
  });
});
