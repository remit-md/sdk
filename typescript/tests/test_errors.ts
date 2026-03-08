import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  fromErrorCode,
  RemitError,
  InsufficientBalanceError,
  EscrowNotFoundError,
  InvalidSignatureError,
  TabNotFoundError,
  StreamNotFoundError,
  BountyNotFoundError,
  RateLimitedError,
  ChainMismatchError,
  DisputeAlreadyFiledError,
} from "../src/errors.js";

describe("Error classes", () => {
  it("RemitError base has code and httpStatus", () => {
    const e = new RemitError("test", "MY_CODE", 418);
    assert.equal(e.code, "MY_CODE");
    assert.equal(e.httpStatus, 418);
    assert.equal(e.message, "test");
    assert(e instanceof Error);
  });

  it("typed subclasses have correct codes", () => {
    assert.equal(new InsufficientBalanceError().code, "INSUFFICIENT_BALANCE");
    assert.equal(new EscrowNotFoundError().code, "ESCROW_NOT_FOUND");
    assert.equal(new InvalidSignatureError().code, "INVALID_SIGNATURE");
    assert.equal(new TabNotFoundError().code, "TAB_NOT_FOUND");
    assert.equal(new StreamNotFoundError().code, "STREAM_NOT_FOUND");
    assert.equal(new BountyNotFoundError().code, "BOUNTY_NOT_FOUND");
    assert.equal(new RateLimitedError().code, "RATE_LIMITED");
    assert.equal(new ChainMismatchError().code, "CHAIN_MISMATCH");
    assert.equal(new DisputeAlreadyFiledError().code, "DISPUTE_ALREADY_FILED");
  });

  it("typed subclasses are instanceof RemitError", () => {
    assert(new InsufficientBalanceError() instanceof RemitError);
    assert(new EscrowNotFoundError() instanceof RemitError);
    assert(new RateLimitedError() instanceof RemitError);
  });

  it("fromErrorCode returns correct subclass", () => {
    const e = fromErrorCode("INSUFFICIENT_BALANCE", "custom message");
    assert(e instanceof InsufficientBalanceError);
    assert.equal(e.message, "custom message");
  });

  it("fromErrorCode with unknown code returns base RemitError", () => {
    const e = fromErrorCode("TOTALLY_UNKNOWN_CODE");
    assert(e instanceof RemitError);
    assert.equal(e.code, "TOTALLY_UNKNOWN_CODE");
  });

  it("fromErrorCode uses default message when none provided", () => {
    const e = fromErrorCode("ESCROW_NOT_FOUND");
    assert(e.message.length > 0);
  });

  it("error name equals class name", () => {
    const e = new InsufficientBalanceError();
    assert.equal(e.name, "InsufficientBalanceError");
  });

  it("errors all have positive httpStatus", () => {
    const codes = [
      "INSUFFICIENT_BALANCE",
      "ESCROW_NOT_FOUND",
      "TAB_NOT_FOUND",
      "RATE_LIMITED",
      "CHAIN_MISMATCH",
      "DISPUTE_ALREADY_FILED",
      "VERSION_MISMATCH",
    ];
    for (const code of codes) {
      const e = fromErrorCode(code);
      assert(e.httpStatus >= 400 && e.httpStatus < 600, `${code} has invalid httpStatus ${e.httpStatus}`);
    }
  });
});
