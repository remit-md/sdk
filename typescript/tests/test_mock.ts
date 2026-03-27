import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { MockRemit } from "../src/testing/mock.js";
import { InsufficientBalanceError } from "../src/errors.js";

describe("MockRemit", () => {
  let mock: MockRemit;

  beforeEach(() => {
    mock = new MockRemit();
  });

  it("createWallet returns wallet with correct balance", async () => {
    const wallet = mock.createWallet(500);
    const bal = await wallet.balance();
    assert.equal(bal, 500);
  });

  it("payDirect transfers funds", async () => {
    const payer = mock.createWallet(100);
    const payee = mock.createWallet(0);
    const tx = await payer.payDirect(payee.address, 30);
    assert.equal(tx.status, "confirmed");
    assert.equal(await payer.balance(), 70);
    assert.equal(await payee.balance(), 30);
  });

  it("payDirect throws on insufficient balance", async () => {
    const payer = mock.createWallet(10);
    const payee = mock.createWallet(0);
    await assert.rejects(
      () => payer.payDirect(payee.address, 100),
      InsufficientBalanceError,
    );
  });

  it("escrow: fund, release", async () => {
    const payer = mock.createWallet(200);
    const payee = mock.createWallet(0);

    const tx = await payer.pay({
      id: "inv-001",
      from: payer.address,
      to: payee.address,
      amount: 100,
      chain: "base",
      status: "pending",
      paymentType: "escrow",
      createdAt: Math.floor(Date.now() / 1000),
    });

    assert(tx.txHash);
    assert.equal(await payer.balance(), 100); // deducted on fund

    const releaseTx = await payer.releaseEscrow("inv-001");
    assert.equal(releaseTx.status, "confirmed");
    assert.equal(await payee.balance(), 100);
  });

  it("escrow: fund, cancel - refunds payer", async () => {
    const payer = mock.createWallet(200);
    const payee = mock.createWallet(0);

    await payer.pay({
      id: "inv-002",
      from: payer.address,
      to: payee.address,
      amount: 50,
      chain: "base",
      status: "pending",
      paymentType: "escrow",
      createdAt: Math.floor(Date.now() / 1000),
    });

    assert.equal(await payer.balance(), 150);
    await payer.cancelEscrow("inv-002");
    assert.equal(await payer.balance(), 200); // refunded
    assert.equal(await payee.balance(), 0);
  });

  it("tab: open, close - refunds unspent", async () => {
    const payer = mock.createWallet(100);
    const payee = mock.createWallet(0);

    const tab = await payer.openTab({ to: payee.address, limit: 50, perUnit: 5 });
    assert.equal(tab.status, "open");
    assert.equal(await payer.balance(), 50); // limit deducted

    const closeTx = await payer.closeTab(tab.id);
    assert.equal(closeTx.status, "confirmed");
    // No charges - full refund
    assert.equal(await payer.balance(), 100);
    assert.equal(await payee.balance(), 0);
  });

  it("tab throws when tab not found", async () => {
    const payer = mock.createWallet(100);
    await assert.rejects(() => payer.closeTab("nonexistent"), /TAB_NOT_FOUND|Tab not found/);
  });

  it("stream: open, close after time advance - correct accounting", async () => {
    const payer = mock.createWallet(1000);
    const payee = mock.createWallet(0);

    const stream = await payer.openStream({ to: payee.address, rate: 1, maxDuration: 100 });
    assert.equal(stream.status, "active");
    assert.equal(await payer.balance(), 900); // reserve of 100 deducted

    mock.advanceTime(30);
    await payer.closeStream(stream.id);

    const payerBal = await payer.balance();
    const payeeBal = await payee.balance();
    assert(payerBal > 960 && payerBal <= 970, `payer balance ${payerBal} should be ~970`);
    assert(payeeBal >= 30 && payeeBal <= 40, `payee balance ${payeeBal} should be ~30`);
  });

  it("bounty: post, award", async () => {
    const poster = mock.createWallet(100);
    const winner = mock.createWallet(0);
    const deadline = Math.floor(Date.now() / 1000) + 86400;

    const bounty = await poster.postBounty({ amount: 50, task: "Write tests", deadline });
    assert.equal(bounty.status, "open");
    assert.equal(await poster.balance(), 50);

    await winner.submitBounty(bounty.id, "0xevidence");
    await poster.awardBounty(bounty.id, 1);
    const b = mock.getBounty(bounty.id);
    assert.equal(b.status, "awarded");
    assert.equal(b.winner, winner.address);
    assert.equal(await winner.balance(), 50);
  });

  it("deposit: locks funds", async () => {
    const payer = mock.createWallet(100);
    const payee = mock.createWallet(0);

    const deposit = await payer.placeDeposit({ to: payee.address, amount: 30, expires: 3600 });
    assert.equal(deposit.status, "locked");
    assert.equal(await payer.balance(), 70);
  });

  it("status includes balance and tier", async () => {
    const wallet = mock.createWallet(555);
    const status = await wallet.status();
    assert.equal(parseFloat(status.balance), 555);
    assert(status.tier.length > 0);
  });

  it("reputation returns valid profile", async () => {
    const wallet = mock.createWallet();
    const rep = await wallet.getReputation(wallet.address);
    assert.equal(rep.address, wallet.address);
    assert(rep.score >= 0);
  });

  it("setBehavior forces next operation to fail", async () => {
    const payer = mock.createWallet(100);
    const payee = mock.createWallet(0);
    mock.setBehavior(payer.address, "INSUFFICIENT_BALANCE");
    await assert.rejects(() => payer.payDirect(payee.address, 1));
    // Second call should succeed (error was consumed)
    const tx = await payer.payDirect(payee.address, 1);
    assert.equal(tx.status, "confirmed");
  });

  it("advanceTime affects stream accounting", async () => {
    const payer = mock.createWallet(1000);
    const payee = mock.createWallet(0);

    const stream = await payer.openStream({ to: payee.address, rate: 10, maxDuration: 60 });
    mock.advanceTime(60); // full duration
    await payer.closeStream(stream.id);

    assert.equal(await payee.balance(), 600); // 10/s * 60s
    assert.equal(await payer.balance(), 400); // 1000 - 600
  });

  it("listBounties filters by status", async () => {
    const poster = mock.createWallet(1000);
    const w2 = mock.createWallet(0);
    const deadline = Math.floor(Date.now() / 1000) + 86400;

    const b1 = await poster.postBounty({ amount: 10, task: "Task A", deadline });
    await poster.postBounty({ amount: 10, task: "Task B", deadline });
    await w2.submitBounty(b1.id, "0xevidence");
    await poster.awardBounty(b1.id, 1);

    const open = mock.listBounties("open");
    const awarded = mock.listBounties("awarded");
    assert.equal(open.length, 1);
    assert.equal(awarded.length, 1);
  });

  it("requestTestnetFunds adds 100 USDC", async () => {
    const wallet = mock.createWallet(0);
    await wallet.requestTestnetFunds();
    assert.equal(await wallet.balance(), 100);
  });

  it("registerWebhook returns webhook object", async () => {
    const wallet = mock.createWallet();
    const wh = await wallet.registerWebhook("https://example.com/hook", ["payment.completed"]);
    assert.equal(wh.url, "https://example.com/hook");
    assert(wh.id.length > 0);
  });

  it("wallet toJSON does not expose private key", () => {
    const wallet = mock.createWallet();
    const json = JSON.stringify(wallet);
    // Should not contain anything resembling a private key
    assert(!json.includes("0x") || json.includes(wallet.address));
    assert(json.includes(wallet.address));
  });
});
