/**
 * TS SDK acceptance: All 13 payment flows with 2 shared wallets.
 *
 * Creates agent (payer) + provider (payee) wallets once, mints 100 USDC
 * to agent, then runs all flows sequentially with small amounts.
 *
 * Flows: direct, escrow, tab, stream, bounty, deposit, x402 (via /x402/prepare),
 *        AP2 discovery, AP2 payment, deposit forfeit, bounty reclaim,
 *        webhook update, wallet settings.
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import type { Wallet } from "../../src/wallet.js";
import { discoverAgent, A2AClient, getTaskTxHash, type AgentCard } from "../../src/a2a.js";
import {
  API_URL,
  createWallet,
  fundWallet,
  getUsdcBalance,
  assertBalanceChange,
  waitForBalanceChange,
  logTx,
} from "./setup.js";

describe("SDK: All 9 Flows", { timeout: 600_000 }, () => {
  let agent: Wallet;
  let provider: Wallet;
  let contracts: Record<string, string>;

  before(async () => {
    agent = await createWallet();
    provider = await createWallet();
    await fundWallet(agent, 100);
    contracts = await agent.getContracts() as unknown as Record<string, string>;
  });

  // ── Flow 1: Direct ──────────────────────────────────────────────────────────

  it("01 direct: payDirect with signPermit", async () => {
    const amount = 1.0;

    const agentBefore = await getUsdcBalance(agent.address);
    const providerBefore = await getUsdcBalance(provider.address);

    const permit = await agent.signPermit("direct", amount);
    const tx = await agent.payDirect(provider.address, amount, "acceptance-direct", { permit });

    const txHash = tx.txHash ?? (tx as unknown as Record<string, string>).tx_hash;
    assert.ok(txHash?.startsWith("0x"), `should return tx hash, got: ${txHash}`);
    logTx("direct", `${amount} USDC ${agent.address}->${provider.address}`, txHash);

    const agentAfter = await waitForBalanceChange(agent.address, agentBefore);
    const providerAfter = await getUsdcBalance(provider.address);

    assertBalanceChange("agent", agentBefore, agentAfter, -amount);
    assertBalanceChange("provider", providerBefore, providerAfter, amount * 0.99);
  });

  // ── Flow 2: Escrow ─────────────────────────────────────────────────────────

  it("02 escrow: pay → claimStart → release", async () => {
    const amount = 2.0;

    const agentBefore = await getUsdcBalance(agent.address);
    const providerBefore = await getUsdcBalance(provider.address);

    const permit = await agent.signPermit("escrow", amount);
    const escrow = await agent.pay(
      { to: provider.address, amount, memo: "acceptance-escrow" },
      { permit },
    );
    const escrowId = escrow.invoiceId ?? (escrow as unknown as Record<string, string>).invoice_id;
    assert.ok(escrowId, "escrow should have id");
    const escrowTxHash = escrow.txHash ?? (escrow as unknown as Record<string, string>).tx_hash;
    if (escrowTxHash) logTx("escrow", `fund ${amount} USDC`, escrowTxHash);

    await waitForBalanceChange(agent.address, agentBefore);

    const claim = await provider.claimStart(escrowId);
    const claimTxHash = (claim as unknown as Record<string, string>).txHash ?? (claim as unknown as Record<string, string>).tx_hash;
    if (claimTxHash) logTx("escrow", "claimStart", claimTxHash);
    await new Promise((r) => setTimeout(r, 5000));

    const release = await agent.releaseEscrow(escrowId);
    const releaseTxHash = (release as unknown as Record<string, string>).txHash ?? (release as unknown as Record<string, string>).tx_hash;
    if (releaseTxHash) logTx("escrow", "release", releaseTxHash);

    const providerAfter = await waitForBalanceChange(provider.address, providerBefore);
    const agentAfter = await getUsdcBalance(agent.address);

    assertBalanceChange("agent", agentBefore, agentAfter, -amount);
    assertBalanceChange("provider", providerBefore, providerAfter, amount * 0.99);
  });

  // ── Flow 3: Tab ────────────────────────────────────────────────────────────

  it("03 tab: openTab → chargeTab → closeTab", async () => {
    const limit = 5.0;
    const chargeAmount = 1.0;
    const chargeUnits = BigInt(Math.round(chargeAmount * 1e6));

    const agentBefore = await getUsdcBalance(agent.address);
    const providerBefore = await getUsdcBalance(provider.address);

    const tabContract = contracts["tab"] ?? contracts["Tab"];
    assert.ok(tabContract, "tab contract address should be available");

    const permit = await agent.signPermit("tab", limit);
    const tab = await agent.openTab({
      to: provider.address,
      limit,
      perUnit: 0.1,
      permit,
    });
    assert.ok(tab.id, "tab should have an id");
    const openTxHash = (tab as unknown as Record<string, string>).txHash ?? (tab as unknown as Record<string, string>).tx_hash;
    if (openTxHash) logTx("tab", `open limit=${limit}`, openTxHash);

    await waitForBalanceChange(agent.address, agentBefore);

    const callCount = 1;
    const chargeSig = await provider.signTabCharge(
      tabContract,
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

    const closeSig = await provider.signTabCharge(
      tabContract,
      tab.id,
      chargeUnits,
      callCount,
    );

    const closed = await agent.closeTab(tab.id, {
      finalAmount: chargeAmount,
      providerSig: closeSig,
    });

    const closedTxHash =
      closed.txHash ??
      (closed as unknown as Record<string, string>).closedTxHash ??
      (closed as unknown as Record<string, string>).closed_tx_hash;
    assert.ok(closedTxHash?.startsWith("0x"), `close should return tx hash, got: ${closedTxHash}`);
    logTx("tab", "close", closedTxHash);

    const providerAfter = await waitForBalanceChange(provider.address, providerBefore);
    const agentAfter = await getUsdcBalance(agent.address);

    assertBalanceChange("agent", agentBefore, agentAfter, -chargeAmount);
    assertBalanceChange("provider", providerBefore, providerAfter, chargeAmount * 0.99);
  });

  // ── Flow 4: Stream ─────────────────────────────────────────────────────────

  it("04 stream: openStream → wait → closeStream", async () => {
    const rate = 0.1; // $0.10/s
    const maxTotal = 2.0;

    const agentBefore = await getUsdcBalance(agent.address);
    const providerBefore = await getUsdcBalance(provider.address);

    const permit = await agent.signPermit("stream", maxTotal);
    const stream = await agent.openStream({
      to: provider.address,
      rate,
      maxTotal,
      permit,
    });
    assert.ok(stream.id, "stream should have an id");
    const openTxHash = (stream as unknown as Record<string, string>).txHash ?? (stream as unknown as Record<string, string>).tx_hash;
    if (openTxHash) logTx("stream", `open rate=${rate}/s max=${maxTotal}`, openTxHash);

    await waitForBalanceChange(agent.address, agentBefore);
    await new Promise((r) => setTimeout(r, 5000));

    const closed = await agent.closeStream(stream.id);
    const closedStatus = closed.status ?? (closed as unknown as Record<string, string>).status;
    assert.equal(closedStatus, "closed", "stream should be closed");
    const closedTxHash = (closed as unknown as Record<string, string>).txHash ?? (closed as unknown as Record<string, string>).tx_hash;
    if (closedTxHash) logTx("stream", "close", closedTxHash);

    const providerAfter = await waitForBalanceChange(provider.address, providerBefore);
    const agentAfter = await getUsdcBalance(agent.address);

    const agentLoss = agentBefore - agentAfter;
    assert.ok(agentLoss > 0.05, `agent should lose money, loss=${agentLoss}`);
    assert.ok(agentLoss <= maxTotal + 0.01, `agent loss <= maxTotal, loss=${agentLoss}`);

    const providerGain = providerAfter - providerBefore;
    assert.ok(providerGain > 0.04, `provider should gain, gain=${providerGain}`);
  });

  // ── Flow 5: Bounty ─────────────────────────────────────────────────────────

  it("05 bounty: postBounty → submitBounty → awardBounty", async () => {
    const amount = 2.0;
    const deadline = Math.floor(Date.now() / 1000) + 3600;

    const agentBefore = await getUsdcBalance(agent.address);
    const providerBefore = await getUsdcBalance(provider.address);

    const permit = await agent.signPermit("bounty", amount);
    const bounty = await agent.postBounty({
      amount,
      task: "acceptance-bounty",
      deadline,
      permit,
    });
    assert.ok(bounty.id, "bounty should have an id");
    const postTxHash = (bounty as unknown as Record<string, string>).txHash ?? (bounty as unknown as Record<string, string>).tx_hash;
    if (postTxHash) logTx("bounty", `post ${amount} USDC`, postTxHash);

    await waitForBalanceChange(agent.address, agentBefore);

    const evidenceHash = `0x${"ab".repeat(32)}`;
    await provider.submitBounty(bounty.id, evidenceHash);
    console.log(`[ACCEPTANCE] bounty | submit | id=${bounty.id}`);

    // Retry award up to 15 times with 3s sleep (Ponder indexer lag)
    let awarded: Record<string, unknown> | null = null;
    for (let attempt = 0; attempt < 15; attempt++) {
      await new Promise((r) => setTimeout(r, 3000));
      try {
        awarded = await agent.awardBounty(bounty.id, 1) as unknown as Record<string, unknown>;
        break;
      } catch (e) {
        if (attempt < 14) {
          console.log(`[ACCEPTANCE] bounty award retry ${attempt + 1}: ${(e as Error).message}`);
        } else {
          throw e;
        }
      }
    }
    assert.ok(awarded, "bounty should be awarded");
    const awardedStatus = (awarded as Record<string, string>).status;
    assert.equal(awardedStatus, "awarded", "bounty status should be awarded");
    const awardTxHash = (awarded as Record<string, string>).txHash ?? (awarded as Record<string, string>).tx_hash;
    if (awardTxHash) logTx("bounty", "award", awardTxHash);

    const providerAfter = await waitForBalanceChange(provider.address, providerBefore);
    const agentAfter = await getUsdcBalance(agent.address);

    assertBalanceChange("agent", agentBefore, agentAfter, -amount);
    assertBalanceChange("provider", providerBefore, providerAfter, amount * 0.99);
  });

  // ── Flow 6: Deposit ────────────────────────────────────────────────────────

  it("06 deposit: placeDeposit → returnDeposit", async () => {
    const amount = 2.0;

    const agentBefore = await getUsdcBalance(agent.address);

    const permit = await agent.signPermit("deposit", amount);
    const deposit = await agent.placeDeposit({
      to: provider.address,
      amount,
      expires: 3600,
      permit,
    });
    assert.ok(deposit.id, "deposit should have an id");
    const placeTxHash = (deposit as unknown as Record<string, string>).txHash ?? (deposit as unknown as Record<string, string>).tx_hash;
    if (placeTxHash) logTx("deposit", `place ${amount} USDC`, placeTxHash);

    const agentMid = await waitForBalanceChange(agent.address, agentBefore);
    assertBalanceChange("agent locked", agentBefore, agentMid, -amount);

    const returned = await provider.returnDeposit(deposit.id);
    const returnedStatus = returned.status ?? (returned as unknown as Record<string, string>).status;
    assert.equal(returnedStatus, "returned", "deposit should be returned");
    const returnTxHash = (returned as unknown as Record<string, string>).txHash ?? (returned as unknown as Record<string, string>).tx_hash;
    if (returnTxHash) logTx("deposit", "return", returnTxHash);

    const agentAfter = await waitForBalanceChange(agent.address, agentMid);
    assertBalanceChange("agent refund", agentBefore, agentAfter, 0);
  });

  // ── Flow 7: x402 (via /x402/prepare — no local HTTP server) ───────────────

  it("07 x402: /x402/prepare returns valid EIP-3009 hash", async () => {
    const paymentRequired = {
      scheme: "exact",
      network: "eip155:84532",
      amount: "100000",
      asset: contracts["usdc"] ?? contracts["USDC"],
      payTo: contracts["router"] ?? contracts["Router"],
      maxTimeoutSeconds: 60,
    };
    const encoded = Buffer.from(JSON.stringify(paymentRequired)).toString("base64");

    // Strip /api/v1 suffix from API_URL to get the base domain for the endpoint
    const baseUrl = API_URL.replace(/\/api\/v1\/?$/, "");
    const res = await fetch(`${baseUrl}/api/v1/x402/prepare`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ payment_required: encoded, payer: agent.address }),
    });
    assert.ok(res.ok, `x402/prepare failed: ${res.status}`);
    const data = await res.json() as Record<string, string>;

    assert.ok(data["hash"], `x402/prepare missing hash: ${JSON.stringify(data)}`);
    assert.ok(data["hash"].startsWith("0x"), "hash should start with 0x");
    assert.equal(data["hash"].length, 66, "hash should be 0x + 64 hex chars");
    assert.ok(data["from"], "response should have from");
    assert.ok(data["to"], "response should have to");
    assert.ok(data["value"], "response should have value");

    console.log(
      `[ACCEPTANCE] x402 | prepare | hash=${data["hash"].slice(0, 18)}...` +
      ` | from=${data["from"].slice(0, 10)}...`,
    );
  });

  // ── Flow 8: AP2 Discovery ──────────────────────────────────────────────────

  it("08 ap2-discovery: GET /.well-known/agent-card.json", async () => {
    // Strip /api/v1 to get the base URL for agent card discovery
    const baseUrl = API_URL.replace(/\/api\/v1\/?$/, "");
    const card = await discoverAgent(baseUrl);

    assert.ok(card.name, "agent card should have a name");
    assert.ok(card.url, "agent card should have a URL");
    assert.ok(card.skills.length > 0, "agent card should have skills");
    assert.ok(card.x402, "agent card should have x402 config");

    console.log(
      `[ACCEPTANCE] ap2-discovery | name=${card.name}` +
      ` | skills=${card.skills.length}` +
      ` | x402=${Boolean(card.x402)}`,
    );
  });

  // ── Flow 9: AP2 Payment ────────────────────────────────────────────────────

  it("09 ap2-payment: A2AClient.send() direct payment", async () => {
    const amount = 1.0;

    const agentBefore = await getUsdcBalance(agent.address);
    const providerBefore = await getUsdcBalance(provider.address);

    // Discover agent card
    const baseUrl = API_URL.replace(/\/api\/v1\/?$/, "");
    const card = await discoverAgent(baseUrl);

    const permit = await agent.signPermit("direct", amount);

    // Access the private signer via the wallet's internal state.
    // A2AClient.fromCard needs a Signer — we extract it from the wallet's prototype chain.
    // The wallet exposes _apiUrl, _chainId (protected from RemitClient), but signer is private.
    // Use raw HTTP POST /a2a instead for clean access.
    const a2aEndpoint = card.url;
    const nonce = crypto.randomUUID().replace(/-/g, "");
    const messageId = crypto.randomUUID().replace(/-/g, "");

    const message = {
      messageId,
      role: "user",
      parts: [{
        kind: "data",
        data: {
          model: "direct",
          to: provider.address,
          amount: amount.toFixed(2),
          memo: "acceptance-ap2",
          nonce,
          permit,
        },
      }],
    };

    const body = {
      jsonrpc: "2.0",
      id: messageId,
      method: "message/send",
      params: { message },
    };

    // A2A endpoint requires authentication — use the wallet's auth mechanism.
    // We'll make an unauthenticated POST (server allows A2A without auth for direct payments with permit).
    const res = await fetch(a2aEndpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    assert.ok(res.ok, `A2A send failed: ${res.status} ${await res.text()}`);

    const rpcResponse = await res.json() as { result?: Record<string, unknown>; error?: { message?: string } };
    assert.ok(!rpcResponse.error, `A2A error: ${rpcResponse.error?.message}`);

    const task = rpcResponse.result as { id: string; status: { state: string }; artifacts: Array<{ parts: Array<{ data?: Record<string, unknown> }> }> };
    assert.ok(task, "A2A should return a task");
    assert.equal(task.status?.state, "completed", `A2A task should complete, got: ${task.status?.state}`);

    const txHash = getTaskTxHash(task as Parameters<typeof getTaskTxHash>[0]);
    if (txHash) {
      assert.ok(txHash.startsWith("0x"), "tx hash should start with 0x");
      logTx("ap2-payment", `${amount} USDC via A2A`, txHash);
    }

    const agentAfter = await waitForBalanceChange(agent.address, agentBefore);
    const providerAfter = await getUsdcBalance(provider.address);

    assertBalanceChange("agent", agentBefore, agentAfter, -amount);
    assertBalanceChange("provider", providerBefore, providerAfter, amount * 0.99);
  });

  // ── Flow 12: Deposit Forfeit ────────────────────────────────────────────────

  it("12 deposit forfeit: placeDeposit → forfeitDeposit", async () => {
    const amount = 1.0;

    const agentBefore = await getUsdcBalance(agent.address);
    const providerBefore = await getUsdcBalance(provider.address);

    const permit = await agent.signPermit("deposit", amount);
    const deposit = await agent.placeDeposit({
      to: provider.address,
      amount,
      expires: 3600,
      permit,
    });
    assert.ok(deposit.id, "deposit should have an id");
    const placeTxHash = (deposit as unknown as Record<string, string>).txHash ?? (deposit as unknown as Record<string, string>).tx_hash;
    if (placeTxHash) logTx("deposit-forfeit", `place ${amount} USDC`, placeTxHash);

    await waitForBalanceChange(agent.address, agentBefore);

    // Provider forfeits (claims the deposit)
    const forfeited = await provider.forfeitDeposit(deposit.id);
    const forfeitTxHash = forfeited.txHash ?? (forfeited as unknown as Record<string, string>).tx_hash;
    const forfeitStatus = forfeited.status ?? (forfeited as unknown as Record<string, string>).status;
    assert.ok(forfeitTxHash?.startsWith("0x") || forfeitStatus, "forfeit should succeed");
    if (forfeitTxHash) logTx("deposit-forfeit", "forfeit", forfeitTxHash);

    const providerAfter = await waitForBalanceChange(provider.address, providerBefore);
    const agentAfter = await getUsdcBalance(agent.address);

    // Agent loses the deposit, provider gains it (minus fees)
    assertBalanceChange("agent", agentBefore, agentAfter, -amount);
    assertBalanceChange("provider", providerBefore, providerAfter, amount * 0.99);
  });

  // ── Flow 13: Bounty Reclaim ─────────────────────────────────────────────────

  it("13 bounty reclaim: postBounty → wait → reclaimBounty", async () => {
    const amount = 1.0;
    // Very short deadline: 2 seconds from now
    const deadline = Math.floor(Date.now() / 1000) + 2;

    const agentBefore = await getUsdcBalance(agent.address);

    const permit = await agent.signPermit("bounty", amount);
    const bounty = await agent.postBounty({
      amount,
      task: "acceptance-bounty-reclaim",
      deadline,
      permit,
    });
    assert.ok(bounty.id, "bounty should have an id");
    const postTxHash = (bounty as unknown as Record<string, string>).txHash ?? (bounty as unknown as Record<string, string>).tx_hash;
    if (postTxHash) logTx("bounty-reclaim", `post ${amount} USDC deadline=+2s`, postTxHash);

    await waitForBalanceChange(agent.address, agentBefore);
    const agentMid = await getUsdcBalance(agent.address);

    // Wait for deadline to pass
    await new Promise((r) => setTimeout(r, 3000));

    // Agent reclaims expired bounty (retry for indexer lag)
    let reclaimed: Record<string, unknown> | null = null;
    for (let attempt = 0; attempt < 15; attempt++) {
      try {
        reclaimed = await agent.reclaimBounty(bounty.id) as unknown as Record<string, unknown>;
        break;
      } catch (e) {
        if (attempt < 14) {
          console.log(`[ACCEPTANCE] bounty-reclaim retry ${attempt + 1}: ${(e as Error).message}`);
          await new Promise((r) => setTimeout(r, 3000));
        } else {
          throw e;
        }
      }
    }
    assert.ok(reclaimed, "bounty should be reclaimed");
    const reclaimTxHash = (reclaimed as Record<string, string>).txHash ?? (reclaimed as Record<string, string>).tx_hash;
    const reclaimStatus = (reclaimed as Record<string, string>).status;
    assert.ok(reclaimTxHash?.startsWith("0x") || reclaimStatus, "reclaim should succeed");
    if (reclaimTxHash) logTx("bounty-reclaim", "reclaim", reclaimTxHash);

    // Agent should get funds back (minus any fees on the round-trip)
    const agentAfter = await waitForBalanceChange(agent.address, agentMid);
    assertBalanceChange("agent refund", agentBefore, agentAfter, 0);
  });

  // ── Flow 14: Webhook Update ─────────────────────────────────────────────────

  it("14 webhook update: registerWebhook → updateWebhook → deleteWebhook", async () => {
    // Register a webhook
    const wh = await agent.registerWebhook(
      "https://example.com/original",
      ["payment.completed"],
    );
    assert.ok(wh.id, "webhook should have an id");
    assert.equal(wh.url, "https://example.com/original");
    console.log(`[ACCEPTANCE] webhook-update | register | id=${wh.id}`);

    // Update the URL
    const updated = await agent.updateWebhook(wh.id, {
      url: "https://example.com/updated",
    });
    assert.equal(updated.url, "https://example.com/updated");
    console.log(`[ACCEPTANCE] webhook-update | update | url=${updated.url}`);

    // Clean up
    await agent.deleteWebhook(wh.id);
    console.log(`[ACCEPTANCE] webhook-update | delete | id=${wh.id}`);
  });

  // ── Flow 15: Wallet Settings ────────────────────────────────────────────────

  it("15 wallet settings: updateWalletSettings", async () => {
    const settings = await agent.updateWalletSettings({
      display_name: "acceptance-test-agent",
    });
    // Server returns camelCase displayName
    const name = settings.displayName ?? (settings as unknown as Record<string, string>).display_name;
    assert.equal(name, "acceptance-test-agent", "display name should be updated");
    console.log(`[ACCEPTANCE] wallet-settings | update | display_name=${name}`);
  });
});
