/**
 * SDK acceptance: Tab lifecycle via wallet.openTab(), chargeTab(), closeTab().
 * Verifies SDK permit signing + tab charge signing + full lifecycle balances.
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

describe("SDK: Tab Lifecycle", { timeout: 180_000 }, () => {
  let agent: Wallet;
  let provider: Wallet;

  before(async () => {
    agent = await createWallet();
    provider = await createWallet();
    await fundWallet(agent, 100);
  });

  it("openTab → chargeTab → closeTab with correct balances", async () => {
    const limit = 10.0;
    const chargeAmount = 2.0;
    const chargeUnits = BigInt(Math.round(chargeAmount * 1e6));
    const fee = chargeAmount * 0.01; // 1% = $0.02
    const providerReceives = chargeAmount - fee; // $1.98

    const agentBefore = await getUsdcBalance(agent.address);
    const providerBefore = await getUsdcBalance(provider.address);
    const feeBefore = await getFeeWalletBalance();

    // Step 1: Open tab (agent, with permit for Tab contract)
    const contracts = await agent.getContracts();
    const permit = await agent.signPermit(contracts.tab, limit + 1);

    const tab = await agent.openTab({
      to: provider.address,
      limit,
      perUnit: 0.1,
      permit,
    });

    assert.ok(tab.id, "tab should have an id");

    // Wait for on-chain lock (agent USDC moves to Tab contract)
    await waitForBalanceChange(agent.address, agentBefore);

    // Step 2: Provider charges $2 (off-chain with TabCharge EIP-712 sig)
    const callCount = 1;
    const chargeSig = await provider.signTabCharge(
      contracts.tab,
      tab.id,
      chargeUnits,
      callCount,
    );

    const charge = await provider.chargeTab(tab.id, {
      amount: chargeAmount,
      cumulative: chargeAmount,
      callCount,
      providerSig: chargeSig,
    });

    const chargeTabId = charge.tabId ?? (charge as unknown as Record<string, string>).tab_id;
    assert.equal(chargeTabId, tab.id, "charge should reference the tab");

    // Step 3: Close tab (agent, with provider's close signature on final state)
    const closeSig = await provider.signTabCharge(
      contracts.tab,
      tab.id,
      chargeUnits,
      callCount,
    );

    const closed = await agent.closeTab(tab.id, {
      finalAmount: chargeAmount,
      providerSig: closeSig,
    });

    const closedStatus = closed.status ?? (closed as unknown as Record<string, string>).status;
    assert.equal(closedStatus, "closed", "tab should be closed");

    const closedTxHash =
      closed.txHash ??
      (closed as unknown as Record<string, string>).closedTxHash ??
      (closed as unknown as Record<string, string>).closed_tx_hash;
    assert.ok(closedTxHash?.startsWith("0x"), `close should return tx hash, got: ${closedTxHash}`);

    // Verify balances
    const providerAfter = await waitForBalanceChange(provider.address, providerBefore);
    const feeAfter = await getFeeWalletBalance();
    const agentAfter = await getUsdcBalance(agent.address);

    // Agent: locked $10, refunded $8, net change = -$2
    assertBalanceChange("agent", agentBefore, agentAfter, -chargeAmount);
    // Provider: received $2 minus 1% fee = $1.98
    assertBalanceChange("provider", providerBefore, providerAfter, providerReceives);
    // Fee wallet: received 1% of $2 = $0.02
    assertBalanceChange("fee wallet", feeBefore, feeAfter, fee);
  });
});
