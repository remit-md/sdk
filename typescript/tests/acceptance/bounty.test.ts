/**
 * SDK acceptance: Bounty lifecycle via wallet.postBounty(), submitBounty(), awardBounty().
 * Verifies SDK permit signing + full bounty lifecycle with balance assertions.
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

describe("SDK: Bounty Lifecycle", { timeout: 180_000 }, () => {
  let poster: Wallet;
  let provider: Wallet;

  before(async () => {
    poster = await createWallet();
    provider = await createWallet();
    await fundWallet(poster, 100);
  });

  it("postBounty → submitBounty → awardBounty with correct balances", async () => {
    const amount = 5.0;
    const fee = amount * 0.01; // 1% = $0.05
    const providerReceives = amount - fee; // $4.95

    const posterBefore = await getUsdcBalance(poster.address);
    const providerBefore = await getUsdcBalance(provider.address);
    // Step 1: Post bounty with permit for Bounty contract
    const contracts = await poster.getContracts();
    const permit = await poster.signPermit(contracts.bounty, amount + 1);
    const deadline = Math.floor(Date.now() / 1000) + 3600;

    const bounty = await poster.postBounty({
      amount,
      task: "sdk-bounty-acceptance-test",
      deadline,
      permit,
    });

    assert.ok(bounty.id, "bounty should have an id");
    const postTxHash = (bounty as unknown as Record<string, string>).txHash ?? (bounty as unknown as Record<string, string>).tx_hash;
    if (postTxHash) logTx("bounty", "post", postTxHash);

    // Wait for on-chain bounty creation (poster USDC locked in Bounty contract)
    await waitForBalanceChange(poster.address, posterBefore);

    // Step 2: Provider submits evidence
    const evidenceHash = `0x${"ab".repeat(32)}`;
    const submission = await provider.submitBounty(bounty.id, evidenceHash);
    const submissionId =
      (submission as unknown as Record<string, number>).id ??
      (submission as unknown as Record<string, number>).submissionId;

    // Wait for submission tx
    await new Promise((r) => setTimeout(r, 5000));

    // Step 3: Poster awards to the submission
    const awarded = await poster.awardBounty(bounty.id, submissionId);
    const awardedStatus =
      awarded.status ?? (awarded as unknown as Record<string, string>).status;
    assert.equal(awardedStatus, "awarded", "bounty should be awarded");
    const awardTxHash = (awarded as unknown as Record<string, string>).txHash ?? (awarded as unknown as Record<string, string>).tx_hash;
    if (awardTxHash) logTx("bounty", "award", awardTxHash);

    // Verify balances
    const providerAfter = await waitForBalanceChange(provider.address, providerBefore);
    const posterAfter = await getUsdcBalance(poster.address);

    // Poster: lost $5 (bounty amount)
    assertBalanceChange("poster", posterBefore, posterAfter, -amount);
    // Provider: received $5 minus 1% fee = $4.95
    assertBalanceChange("provider", providerBefore, providerAfter, providerReceives);
  });
});
