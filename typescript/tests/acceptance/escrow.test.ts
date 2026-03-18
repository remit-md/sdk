/**
 * SDK acceptance: Escrow lifecycle via wallet.pay(), claimStart(), releaseEscrow().
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import type { Wallet } from "../../src/wallet.js";
import {
  createWallet,
  fundWallet,
  getUsdcBalance,
  getFeeWalletBalance,
  assertBalanceChange,
  waitForBalanceChange,
} from "./setup.js";

describe("SDK: Escrow Lifecycle", { timeout: 180_000 }, () => {
  let agent: Wallet;
  let provider: Wallet;

  before(async () => {
    agent = await createWallet();
    provider = await createWallet();
    await fundWallet(agent, 100);
  });

  it("pay → claimStart → release with correct balances", async () => {
    const amount = 5.0;
    const fee = amount * 0.01;
    const providerReceives = amount - fee;

    const agentBefore = await getUsdcBalance(agent.address);
    const providerBefore = await getUsdcBalance(provider.address);
    const feeBefore = await getFeeWalletBalance();

    // Sign permit for Escrow contract
    const contracts = await agent.getContracts();
    const permit = await agent.signPermit(contracts.escrow, amount + 1);

    // Fund escrow
    const escrow = await agent.pay(
      { to: provider.address, amount, memo: "sdk-escrow-test" },
      { permit },
    );
    const escrowId = escrow.invoiceId ?? (escrow as unknown as Record<string, string>).invoice_id;
    assert.ok(escrowId, "escrow should have id");

    // Wait for lock
    await waitForBalanceChange(agent.address, agentBefore);

    // Provider claims
    await provider.claimStart(escrowId);
    await new Promise((r) => setTimeout(r, 5000));

    // Agent releases
    await agent.releaseEscrow(escrowId);

    // Verify balances
    const providerAfter = await waitForBalanceChange(provider.address, providerBefore);
    const feeAfter = await getFeeWalletBalance();
    const agentAfter = await getUsdcBalance(agent.address);

    assertBalanceChange("agent", agentBefore, agentAfter, -amount);
    assertBalanceChange("provider", providerBefore, providerAfter, providerReceives);
    assertBalanceChange("fee wallet", feeBefore, feeAfter, fee);
  });
});
