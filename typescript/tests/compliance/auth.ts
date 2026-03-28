/**
 * Compliance: EIP-712 authentication against a real server.
 *
 * Proves the TypeScript SDK can authenticate - 200 responses, not 401s.
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

    const wallet = makeWallet();
    console.log(`[COMPLIANCE] auth test: wallet=${wallet.address}`);
    // status() uses #auth.get - if EIP-712 is wrong this returns 401 not 200.
    // Server returns { wallet, tier, monthlyVolume, feeRateBps, ... } (camelized by SDK).
    const status = await wallet.status();
    console.log(`[COMPLIANCE] status: wallet=${wallet.address} tier=${status.tier}`);
    // Server uses "wallet" key (not "address"), cast to access it.
    const raw = status as unknown as Record<string, unknown>;
    assert.equal(
      (raw["wallet"] as string).toLowerCase(),
      wallet.address.toLowerCase(),
      "Server must return our wallet address",
    );
    assert.ok(typeof status.tier === "string" && status.tier.length > 0, "tier must be set");
  });

  it("unauthenticated POST /payments/direct returns 401", async (t) => {
    if (skip) return t.skip("server not available");

    console.log(`[COMPLIANCE] unauthenticated POST /payments/direct (expect 401)`);
    const resp = await fetch(`${SERVER_URL}/api/v1/payments/direct`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        to: ROUTER_ADDRESS,
        amount: 1.0,
      }),
    });
    console.log(`[COMPLIANCE] unauthenticated response: status=${resp.status}`);
    assert.equal(resp.status, 401, `Expected 401, got ${resp.status}`);
  });

  it("mint credits testnet funds", async (t) => {
    if (skip) return t.skip("server not available");

    const wallet = makeWallet();
    console.log(`[COMPLIANCE] mint test: wallet=${wallet.address}`);
    const tx = await wallet.mint(100);
    console.log(`[COMPLIANCE] mint: 100 USDC -> ${wallet.address} tx=${tx.tx_hash}`);
    assert.ok(tx.tx_hash, "tx_hash must be set after mint");
  });

});
