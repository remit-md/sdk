/**
 * SDK acceptance: Deposit lifecycle via wallet.placeDeposit(), returnDeposit().
 * Verifies SDK permit signing + deposit lock/return with full refund (no fee).
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

describe("SDK: Deposit Lifecycle", { timeout: 180_000 }, () => {
  let agent: Wallet;
  let provider: Wallet;

  before(async () => {
    agent = await createWallet();
    provider = await createWallet();
    await fundWallet(agent, 100);
  });

  it("placeDeposit → returnDeposit with full refund (no fee)", async () => {
    const amount = 5.0;

    const agentBefore = await getUsdcBalance(agent.address);
    const providerBefore = await getUsdcBalance(provider.address);
    // Step 1: Place deposit with permit via /permits/prepare
    const permit = await agent.signPermit("deposit", amount + 1);

    const deposit = await agent.placeDeposit({
      to: provider.address,
      amount,
      expires: 3600, // 1 hour
      permit,
    });

    assert.ok(deposit.id, "deposit should have an id");
    const placeTxHash = (deposit as unknown as Record<string, string>).txHash ?? (deposit as unknown as Record<string, string>).tx_hash;
    if (placeTxHash) logTx("deposit", "place", placeTxHash);

    // Wait for on-chain deposit lock
    const agentMid = await waitForBalanceChange(agent.address, agentBefore);
    assertBalanceChange("agent locked", agentBefore, agentMid, -amount);

    // Step 2: Provider returns the deposit
    const returned = await provider.returnDeposit(deposit.id);
    const returnedStatus =
      returned.status ?? (returned as unknown as Record<string, string>).status;
    assert.equal(returnedStatus, "returned", "deposit should be returned");
    const returnTxHash = (returned as unknown as Record<string, string>).txHash ?? (returned as unknown as Record<string, string>).tx_hash;
    if (returnTxHash) logTx("deposit", "return", returnTxHash);

    // Wait for return settlement (agent gets full refund)
    const agentAfter = await waitForBalanceChange(agent.address, agentMid);
    const providerAfter = await getUsdcBalance(provider.address);

    // Agent: full refund - net change ≈ $0
    assertBalanceChange("agent net", agentBefore, agentAfter, 0);
    // Provider: unchanged
    assertBalanceChange("provider", providerBefore, providerAfter, 0);
  });
});
