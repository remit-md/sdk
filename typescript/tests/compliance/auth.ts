/**
 * Compliance: EIP-712 authentication against a real server.
 *
 * Proves the TypeScript SDK can authenticate — 200 responses, not 401s.
 * Requires the compliance server to be running (docker-compose.compliance.yml).
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";

import {
  SERVER_URL,
  ROUTER_ADDRESS,
  serverIsReachable,
  makeWallet,
} from "./helpers.js";

let skip = false;

before(async () => {
  skip = !(await serverIsReachable());
  if (skip) {
    console.warn(
      `[compliance] Server not reachable at ${SERVER_URL}. Skipping auth tests.`,
    );
  }
});

describe("TypeScript compliance: authentication", () => {
  it("authenticated GET /status returns 200", async (t) => {
    if (skip) return t.skip("server not available");

    const wallet = await makeWallet();
    // status() uses #auth.get — if EIP-712 is wrong this returns 401
    const status = await wallet.status();
    assert.equal(status.address.toLowerCase(), wallet.address.toLowerCase());
    assert.equal(typeof status.usdcBalance, "number");
  });

  it("unauthenticated POST /payments/direct returns 401", async (t) => {
    if (skip) return t.skip("server not available");

    const resp = await fetch(`${SERVER_URL}/api/v0/payments/direct`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        to: ROUTER_ADDRESS,
        amount: 1.0,
      }),
    });
    assert.equal(resp.status, 401, `Expected 401, got ${resp.status}`);
  });

  it("faucet credits testnet funds", async (t) => {
    if (skip) return t.skip("server not available");

    const wallet = await makeWallet();
    const tx = await wallet.requestTestnetFunds();
    assert.ok(tx.txHash, "txHash must be set after faucet");
  });

  it("GET /events returns empty list for new wallet", async (t) => {
    if (skip) return t.skip("server not available");

    const wallet = await makeWallet();
    const events = await wallet.getEvents(wallet.address);
    assert.ok(Array.isArray(events), "events must be an array");
    assert.equal(events.length, 0, "fresh wallet must have zero events");
  });
});
