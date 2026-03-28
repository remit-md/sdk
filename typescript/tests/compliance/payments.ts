/**
 * Compliance: pay_direct against a real server.
 *
 * Verifies end-to-end direct payment: mint → payDirect → invoice exists.
 * Requires the compliance server to be running (docker-compose.compliance.yml).
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";

import { SERVER_URL, serverIsReachable, makeFundedPair } from "./helpers.js";
import { RemitError } from "../../src/errors.js";

let skip = false;

before(async () => {
  skip = !(await serverIsReachable());
  if (skip) {
    console.warn(
      `[compliance] Server not reachable at ${SERVER_URL}. Skipping payment tests.`,
    );
  }
});

describe("TypeScript compliance: payDirect", () => {
  it("happy path: payDirect returns tx with txHash and invoiceId", async (t) => {
    if (skip) return t.skip("server not available");

    const { payer, payeeAddress } = await makeFundedPair();
    console.log(`[COMPLIANCE] payDirect: 5.0 USDC ${payer.address} -> ${payeeAddress}`);
    const tx = await payer.payDirect(payeeAddress, 5.0, "compliance test");
    console.log(`[COMPLIANCE] payDirect OK: tx=${tx.txHash} invoice=${tx.invoiceId}`);

    assert.ok(tx.txHash, "txHash must be set");
    assert.ok(tx.invoiceId, "invoiceId must be set");
  });

  it("below minimum amount returns 400/422 error", async (t) => {
    if (skip) return t.skip("server not available");

    const { payer, payeeAddress } = await makeFundedPair();
    console.log(`[COMPLIANCE] payDirect below-minimum: 0.001 USDC ${payer.address} -> ${payeeAddress} (expect 400/422)`);
    await assert.rejects(
      () => payer.payDirect(payeeAddress, 0.001, "too small"),
      (err: unknown) => {
        assert.ok(err instanceof RemitError, "must throw RemitError");
        console.log(`[COMPLIANCE] payDirect below-minimum rejected: status=${err.httpStatus}`);
        assert.ok(
          err.httpStatus === 422 || err.httpStatus === 400,
          `Expected 400/422, got ${err.httpStatus}`,
        );
        return true;
      },
    );
  });

  it("self-payment returns 400/422 error", async (t) => {
    if (skip) return t.skip("server not available");

    const { payer } = await makeFundedPair();
    console.log(`[COMPLIANCE] payDirect self-payment: 1.0 USDC ${payer.address} -> ${payer.address} (expect 400/422)`);
    await assert.rejects(
      () => payer.payDirect(payer.address, 1.0, "self pay"),
      (err: unknown) => {
        assert.ok(err instanceof RemitError, "must throw RemitError");
        console.log(`[COMPLIANCE] payDirect self-payment rejected: status=${err.httpStatus}`);
        assert.ok(
          err.httpStatus === 422 || err.httpStatus === 400,
          `Expected 400/422, got ${err.httpStatus}`,
        );
        return true;
      },
    );
  });
});
