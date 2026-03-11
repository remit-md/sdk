/**
 * Compliance: tab lifecycle against a real server.
 *
 * Verifies: openTab → tab in open state → closeTab → tab no longer open.
 * Requires the compliance server to be running (docker-compose.compliance.yml).
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";

import { SERVER_URL, serverIsReachable, makeFundedPair } from "./helpers.js";

let skip = false;

before(async () => {
  skip = !(await serverIsReachable());
  if (skip) {
    console.warn(
      `[compliance] Server not reachable at ${SERVER_URL}. Skipping tab tests.`,
    );
  }
});

describe("TypeScript compliance: tab lifecycle", () => {
  it("openTab returns tab in open state", async (t) => {
    if (skip) return t.skip("server not available");

    const { payer, payeeAddress } = await makeFundedPair();
    const tab = await payer.openTab({ to: payeeAddress, limit: 20.0, perUnit: 0.10 });

    assert.ok(tab.id, "tab must have an id");
    assert.equal(tab.status, "open");
    assert.ok(Math.abs(tab.limit - 20.0) < 0.01, `Expected limit ~20, got ${tab.limit}`);
  });

  it("closeTab returns tx and tab is no longer open", async (t) => {
    if (skip) return t.skip("server not available");

    const { payer, payeeAddress } = await makeFundedPair();
    const tab = await payer.openTab({ to: payeeAddress, limit: 50.0, perUnit: 1.0 });

    const closeTx = await payer.closeTab(tab.id);
    assert.ok(closeTx.txHash, "closeTx must have txHash");

    const closedTab = await payer.getTab(tab.id);
    assert.notEqual(closedTab.status, "open", "tab must not be open after close");
  });
});
