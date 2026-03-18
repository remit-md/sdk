/**
 * SDK acceptance: Stream lifecycle via wallet.openStream(), closeStream().
 * Verifies SDK permit signing + stream accrual + close with balance bounds.
 *
 * Stream accrual is time-dependent (block timestamps). We use generous bounds
 * and conservation-of-funds checks rather than exact delta assertions.
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import type { Wallet } from "../../src/wallet.js";
import {
  createWallet,
  fundWallet,
  getUsdcBalance,
  getFeeWalletBalance,
  waitForBalanceChange,
} from "./setup.js";

describe("SDK: Stream Lifecycle", { timeout: 180_000 }, () => {
  let agent: Wallet;
  let provider: Wallet;

  before(async () => {
    agent = await createWallet();
    provider = await createWallet();
    await fundWallet(agent, 100);
  });

  it("openStream → wait → closeStream with correct balance bounds", async () => {
    const ratePerSecond = 0.1; // $0.10/s
    const maxTotal = 5.0;

    const agentBefore = await getUsdcBalance(agent.address);
    const providerBefore = await getUsdcBalance(provider.address);
    const feeBefore = await getFeeWalletBalance();

    // Step 1: Open stream with permit for Stream contract
    const contracts = await agent.getContracts();
    const permit = await agent.signPermit(contracts.stream, maxTotal + 1);

    const stream = await agent.openStream({
      to: provider.address,
      rate: ratePerSecond,
      maxTotal,
      permit,
    });

    assert.ok(stream.id, "stream should have an id");

    // Wait for on-chain creation (agent locks maxTotal in Stream contract)
    await waitForBalanceChange(agent.address, agentBefore);

    // Step 2: Wait for accrual (~5 seconds real time)
    await new Promise((r) => setTimeout(r, 5000));

    // Step 3: Close stream (payer only, no body)
    const closed = await agent.closeStream(stream.id);
    const closedStatus = closed.status ?? (closed as unknown as Record<string, string>).status;
    assert.equal(closedStatus, "closed", "stream should be closed");

    // Wait for settlement (provider balance should increase)
    const providerAfter = await waitForBalanceChange(provider.address, providerBefore);
    const feeAfter = await getFeeWalletBalance();
    const agentAfter = await getUsdcBalance(agent.address);

    // Calculate actual changes
    const agentLoss = agentBefore - agentAfter;
    const providerGain = providerAfter - providerBefore;
    const feeGain = feeAfter - feeBefore;

    // Agent should have lost money (stream accrued), but <= maxTotal
    assert.ok(
      agentLoss > 0.05,
      `agent should have lost money from streaming, got loss=${agentLoss}`,
    );
    assert.ok(
      agentLoss <= maxTotal + 0.01,
      `agent loss should not exceed maxTotal ($${maxTotal}), got loss=${agentLoss}`,
    );

    // Provider should have received payout (accrued minus 1% fee)
    assert.ok(
      providerGain > 0.04,
      `provider should have received payout, got gain=${providerGain}`,
    );

    // Fee wallet should not decrease
    assert.ok(feeGain >= 0, `fee wallet should not decrease, got change=${feeGain}`);

    // Conservation of funds: agent loss ≈ provider gain + fee
    const conservationDiff = Math.abs(agentLoss - (providerGain + feeGain));
    assert.ok(
      conservationDiff < 0.01,
      `conservation violated: agent lost ${agentLoss}, provider+fee gained ${providerGain + feeGain}, diff=${conservationDiff}`,
    );
  });
});
