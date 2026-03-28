/**
 * Compliance: escrow lifecycle against a real server.
 *
 * Verifies: create escrow (pay) → funded state → cancel → cancelled state.
 * Requires the compliance server to be running (docker-compose.compliance.yml).
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";

import { SERVER_URL, serverIsReachable, makeFundedPair } from "./helpers.js";
import type { Invoice } from "../../src/models/invoice.js";

let skip = false;

before(async () => {
  skip = !(await serverIsReachable());
  if (skip) {
    console.warn(
      `[compliance] Server not reachable at ${SERVER_URL}. Skipping escrow tests.`,
    );
  }
});

describe("TypeScript compliance: escrow lifecycle", () => {
  it("pay (escrow create) returns tx with invoiceId", async (t) => {
    if (skip) return t.skip("server not available");

    const { payer, payeeAddress } = await makeFundedPair();

    console.log(`[COMPLIANCE] escrow create: 10.0 USDC ${payer.address} -> ${payeeAddress}`);
    const tx = await payer.pay({
      id: "",
      from: payer.address,
      to: payeeAddress,
      amount: 10.0,
      chain: "base-sepolia",
      status: "pending",
      paymentType: "escrow",
      createdAt: 0,
      memo: "compliance escrow test",
    } as Invoice);
    console.log(`[COMPLIANCE] escrow created: id=${tx.invoiceId} tx=${tx.txHash}`);

    assert.ok(tx.invoiceId, "invoiceId must be set after pay");
    assert.ok(tx.txHash, "txHash must be set after pay");
  });

  it("getEscrow returns funded escrow immediately after pay", async (t) => {
    if (skip) return t.skip("server not available");

    const { payer, payeeAddress } = await makeFundedPair();

    console.log(`[COMPLIANCE] escrow create (funded check): 10.0 USDC ${payer.address} -> ${payeeAddress}`);
    const tx = await payer.pay({
      id: "",
      from: payer.address,
      to: payeeAddress,
      amount: 10.0,
      chain: "base-sepolia",
      status: "pending",
      paymentType: "escrow",
      createdAt: 0,
      memo: "compliance escrow funded check",
    } as Invoice);
    console.log(`[COMPLIANCE] escrow created: id=${tx.invoiceId} tx=${tx.txHash}`);

    const escrow = await payer.getEscrow(tx.invoiceId!);
    console.log(`[COMPLIANCE] getEscrow: id=${escrow.invoiceId} status=${escrow.status} amount=${escrow.amount}`);
    assert.equal(escrow.invoiceId, tx.invoiceId);
    assert.equal(escrow.status, "funded");
    assert.ok(
      Math.abs(escrow.amount - 10.0) < 0.01,
      `Expected ~10 USDC, got ${escrow.amount}`,
    );
  });

  it("cancelEscrow transitions escrow to cancelled", async (t) => {
    if (skip) return t.skip("server not available");

    const { payer, payeeAddress } = await makeFundedPair();

    console.log(`[COMPLIANCE] escrow create (cancel test): 10.0 USDC ${payer.address} -> ${payeeAddress}`);
    const tx = await payer.pay({
      id: "",
      from: payer.address,
      to: payeeAddress,
      amount: 10.0,
      chain: "base-sepolia",
      status: "pending",
      paymentType: "escrow",
      createdAt: 0,
      memo: "compliance escrow cancel test",
    } as Invoice);
    console.log(`[COMPLIANCE] escrow created: id=${tx.invoiceId} tx=${tx.txHash}`);

    const cancelTx = await payer.cancelEscrow(tx.invoiceId!);
    console.log(`[COMPLIANCE] escrow cancelled: id=${tx.invoiceId} tx=${cancelTx.txHash}`);
    assert.ok(cancelTx.txHash, "cancelTx must have txHash");

    const escrow = await payer.getEscrow(tx.invoiceId!);
    console.log(`[COMPLIANCE] getEscrow after cancel: id=${escrow.invoiceId} status=${escrow.status}`);
    assert.equal(escrow.status, "cancelled");
  });
});
