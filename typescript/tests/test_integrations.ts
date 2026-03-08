import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { MockRemit } from "../src/testing/mock.js";
import { remitTools } from "../src/integrations/vercel-ai.js";

describe("Vercel AI integration", () => {
  let mock: MockRemit;

  beforeEach(() => {
    mock = new MockRemit();
  });

  it("remitTools returns all expected tool names", () => {
    const payer = mock.createWallet(1000);
    const tools = remitTools(payer);
    const names = Object.keys(tools);

    const expected = [
      "remit_pay_direct",
      "remit_check_balance",
      "remit_get_status",
      "remit_create_escrow",
      "remit_release_escrow",
      "remit_open_tab",
      "remit_close_tab",
      "remit_open_stream",
      "remit_close_stream",
      "remit_post_bounty",
      "remit_place_deposit",
      "remit_file_dispute",
    ];

    for (const name of expected) {
      assert(names.includes(name), `Missing tool: ${name}`);
    }
  });

  it("each tool has description and execute function", () => {
    const payer = mock.createWallet(1000);
    const tools = remitTools(payer);

    for (const [name, tool] of Object.entries(tools)) {
      assert(tool.description.length > 10, `${name} description too short`);
      assert(typeof tool.execute === "function", `${name} execute is not a function`);
    }
  });

  it("remit_check_balance returns balance", async () => {
    const payer = mock.createWallet(750);
    const tools = remitTools(payer);
    const result = (await tools["remit_check_balance"]!.execute()) as { balance: number };
    assert.equal(result.balance, 750);
  });

  it("remit_pay_direct transfers funds", async () => {
    const payer = mock.createWallet(100);
    const payee = mock.createWallet(0);
    const tools = remitTools(payer);

    await tools["remit_pay_direct"]!.execute(payee.address, 20, "test payment");
    assert.equal(await payer.balance(), 80);
    assert.equal(await payee.balance(), 20);
  });

  it("remit_create_escrow creates an escrow", async () => {
    const payer = mock.createWallet(200);
    const payee = mock.createWallet(0);
    const tools = remitTools(payer);

    const tx = (await tools["remit_create_escrow"]!.execute(
      payee.address,
      50,
      "Build a widget",
    )) as { status: string };
    assert.equal(tx.status, "confirmed");
    assert.equal(await payer.balance(), 150);
  });

  it("remit_open_tab opens a tab", async () => {
    const payer = mock.createWallet(100);
    const payee = mock.createWallet(0);
    const tools = remitTools(payer);

    const tab = (await tools["remit_open_tab"]!.execute(payee.address, 40, 2)) as {
      status: string;
      id: string;
    };
    assert.equal(tab.status, "open");
    assert(tab.id.length > 0);
  });

  it("remit_open_stream opens a stream", async () => {
    const payer = mock.createWallet(1000);
    const payee = mock.createWallet(0);
    const tools = remitTools(payer);

    const stream = (await tools["remit_open_stream"]!.execute(payee.address, 0.1, 3600)) as {
      status: string;
      id: string;
    };
    assert.equal(stream.status, "active");
    assert(stream.id.length > 0);
  });

  it("remit_post_bounty posts a bounty", async () => {
    const poster = mock.createWallet(100);
    const tools = remitTools(poster);
    const deadline = Math.floor(Date.now() / 1000) + 86400;

    const bounty = (await tools["remit_post_bounty"]!.execute(30, "Analyze this dataset", deadline)) as {
      status: string;
    };
    assert.equal(bounty.status, "open");
  });
});
