import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { X402Paywall } from "../src/provider.js";

const WALLET = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const ROUTER = "0x887536bD817B758f99F090a80F48032a24f50916";
const USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const NETWORK = "eip155:31337";

function makePaywall(overrides: Partial<ConstructorParameters<typeof X402Paywall>[0]> = {}): X402Paywall {
  return new X402Paywall({
    walletAddress: WALLET,
    routerAddress: ROUTER,
    amountUsdc: 0.001,
    network: NETWORK,
    asset: USDC,
    facilitatorUrl: "http://localhost:3000",
    facilitatorToken: "test-token",
    ...overrides,
  });
}

function encodeSig(payload: unknown): string {
  return Buffer.from(JSON.stringify(payload)).toString("base64");
}

function makeDummyPaymentSig(): string {
  return encodeSig({
    scheme: "exact",
    network: NETWORK,
    x402Version: 1,
    payload: {
      signature: "0xdeadbeef",
      authorization: {
        from: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
        to: WALLET,
        value: "1000",
        validAfter: "0",
        validBefore: "9999999999",
        nonce: "0xabcd1234",
      },
    },
  });
}

function mockFetch(response: { ok: boolean; json: () => unknown }): typeof globalThis.fetch {
  return async () =>
    ({
      ok: response.ok,
      json: async () => response.json(),
    }) as Response;
}

// ─── Construction ─────────────────────────────────────────────────────────────

describe("X402Paywall construction", () => {
  it("toJSON() reveals only non-sensitive fields", () => {
    const pw = makePaywall();
    const j = pw.toJSON();
    assert.equal(j.walletAddress, WALLET);
    assert.equal(j.network, NETWORK);
    // token must not appear
    assert.ok(!("facilitatorToken" in j));
  });
});

// ─── paymentRequiredHeader ────────────────────────────────────────────────────

describe("X402Paywall.paymentRequiredHeader", () => {
  it("produces correctly structured base64 JSON", () => {
    const pw = makePaywall({ amountUsdc: 0.005 });
    const raw = pw.paymentRequiredHeader();
    const payload = JSON.parse(Buffer.from(raw, "base64").toString("utf8")) as {
      scheme: string;
      network: string;
      amount: string;
      asset: string;
      payTo: string;
      maxTimeoutSeconds: number;
    };

    assert.equal(payload.scheme, "exact");
    assert.equal(payload.network, NETWORK);
    assert.equal(payload.amount, "5000"); // 0.005 USDC * 1_000_000
    assert.equal(payload.asset, USDC);
    assert.equal(payload.payTo, ROUTER);
    assert.ok(typeof payload.maxTimeoutSeconds === "number");
  });

  it("converts 0.001 USDC to 1000 base units", () => {
    const pw = makePaywall({ amountUsdc: 0.001 });
    const raw = pw.paymentRequiredHeader();
    const payload = JSON.parse(Buffer.from(raw, "base64").toString("utf8")) as { amount: string };
    assert.equal(payload.amount, "1000");
  });

  it("includes V2 resource/description/mimeType when configured", () => {
    const pw = makePaywall({
      resource: "/v1/data",
      description: "Market data feed",
      mimeType: "application/json",
    });
    const raw = pw.paymentRequiredHeader();
    const payload = JSON.parse(Buffer.from(raw, "base64").toString("utf8")) as Record<string, unknown>;
    assert.equal(payload["resource"], "/v1/data");
    assert.equal(payload["description"], "Market data feed");
    assert.equal(payload["mimeType"], "application/json");
  });

  it("omits V2 fields when not configured", () => {
    const pw = makePaywall();
    const raw = pw.paymentRequiredHeader();
    const payload = JSON.parse(Buffer.from(raw, "base64").toString("utf8")) as Record<string, unknown>;
    assert.ok(!("resource" in payload), "resource must be absent");
    assert.ok(!("description" in payload), "description must be absent");
    assert.ok(!("mimeType" in payload), "mimeType must be absent");
  });
});

// ─── check ─────────────────────────────────────────────────────────────────────

describe("X402Paywall.check", () => {
  it("returns { isValid: false } when payment_sig is null", async () => {
    const pw = makePaywall();
    const result = await pw.check(null);
    assert.equal(result.isValid, false);
    assert.equal(result.invalidReason, undefined);
  });

  it("returns INVALID_PAYLOAD for malformed base64", async () => {
    const pw = makePaywall();
    const result = await pw.check("!!!not-valid-base64!!!");
    assert.equal(result.isValid, false);
    assert.equal(result.invalidReason, "INVALID_PAYLOAD");
  });

  it("returns { isValid: true } when facilitator says valid", async () => {
    const pw = makePaywall();
    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = mockFetch({ ok: true, json: () => ({ isValid: true }) });
      const result = await pw.check(makeDummyPaymentSig());
      assert.equal(result.isValid, true);
    } finally {
      globalThis.fetch = orig;
    }
  });

  it("returns invalidReason when facilitator says invalid", async () => {
    const pw = makePaywall();
    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = mockFetch({
        ok: true,
        json: () => ({ isValid: false, invalidReason: "SIGNATURE_INVALID" }),
      });
      const result = await pw.check(makeDummyPaymentSig());
      assert.equal(result.isValid, false);
      assert.equal(result.invalidReason, "SIGNATURE_INVALID");
    } finally {
      globalThis.fetch = orig;
    }
  });

  it("returns FACILITATOR_ERROR when fetch throws", async () => {
    const pw = makePaywall();
    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = async () => { throw new Error("network error"); };
      const result = await pw.check(makeDummyPaymentSig());
      assert.equal(result.isValid, false);
      assert.equal(result.invalidReason, "FACILITATOR_ERROR");
    } finally {
      globalThis.fetch = orig;
    }
  });

  it("returns FACILITATOR_ERROR when facilitator returns non-ok status", async () => {
    const pw = makePaywall();
    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = mockFetch({ ok: false, json: () => ({}) });
      const result = await pw.check(makeDummyPaymentSig());
      assert.equal(result.isValid, false);
      assert.equal(result.invalidReason, "FACILITATOR_ERROR");
    } finally {
      globalThis.fetch = orig;
    }
  });

  it("sends Authorization header when token is configured", async () => {
    const pw = makePaywall({ facilitatorToken: "my-jwt" });
    let capturedHeaders: Record<string, string> = {};
    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = async (_url: unknown, init?: RequestInit) => {
        capturedHeaders = Object.fromEntries(new Headers(init?.headers).entries());
        return { ok: true, json: async () => ({ isValid: true }) } as Response;
      };
      await pw.check(makeDummyPaymentSig());
    } finally {
      globalThis.fetch = orig;
    }
    assert.equal(capturedHeaders["authorization"], "Bearer my-jwt");
  });

  it("omits Authorization header when no token", async () => {
    const pw = new X402Paywall({ walletAddress: WALLET, routerAddress: ROUTER, amountUsdc: 0.001, network: NETWORK, asset: USDC });
    let capturedHeaders: Record<string, string> = {};
    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = async (_url: unknown, init?: RequestInit) => {
        capturedHeaders = Object.fromEntries(new Headers(init?.headers).entries());
        return { ok: true, json: async () => ({ isValid: true }) } as Response;
      };
      await pw.check(makeDummyPaymentSig());
    } finally {
      globalThis.fetch = orig;
    }
    assert.ok(!("authorization" in capturedHeaders));
  });
});

// ─── handle ────────────────────────────────────────────────────────────────────

describe("X402Paywall.handle", () => {
  it("returns 402 Response when PAYMENT-SIGNATURE header is absent", async () => {
    const pw = makePaywall();
    const req = new Request("http://example.com/v1/data");
    const orig = globalThis.fetch;
    try {
      // check() will return false (null sig) without hitting facilitator
      const resp = await pw.handle(req);
      assert.ok(resp instanceof Response);
      assert.equal(resp!.status, 402);
      assert.ok(resp!.headers.get("payment-required"));
    } finally {
      globalThis.fetch = orig;
    }
  });

  it("returns null when payment is valid", async () => {
    const pw = makePaywall();
    const req = new Request("http://example.com/v1/data", {
      headers: { "payment-signature": makeDummyPaymentSig() },
    });
    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = mockFetch({ ok: true, json: () => ({ isValid: true }) });
      const resp = await pw.handle(req);
      assert.equal(resp, null);
    } finally {
      globalThis.fetch = orig;
    }
  });
});

// ─── honoMiddleware ────────────────────────────────────────────────────────────

describe("X402Paywall.honoMiddleware", () => {
  function makeHonoContext(paymentSig?: string): {
    req: { raw: Request };
    header(name: string, value: string): void;
    body(content: string, status?: number): Response;
  } {
    const headers = new Headers();
    if (paymentSig) headers.set("payment-signature", paymentSig);
    const raw = new Request("http://example.com/v1/data", { headers });
    const resHeaders: Record<string, string> = {};
    return {
      req: { raw },
      header(name: string, value: string) { resHeaders[name] = value; },
      body(content: string, status = 200): Response {
        return new Response(content, { status, headers: resHeaders });
      },
    };
  }

  it("returns 402 Response when payment is absent", async () => {
    const pw = makePaywall();
    const middleware = pw.honoMiddleware();
    const c = makeHonoContext();
    let nextCalled = false;
    const resp = await middleware(c, async () => { nextCalled = true; });
    assert.ok(resp instanceof Response, "should return a Response");
    assert.equal((resp as Response).status, 402);
    assert.ok(!nextCalled, "next should not be called");
  });

  it("calls next when payment is valid", async () => {
    const pw = makePaywall();
    const middleware = pw.honoMiddleware();
    const c = makeHonoContext(makeDummyPaymentSig());
    let nextCalled = false;
    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = mockFetch({ ok: true, json: () => ({ isValid: true }) });
      const resp = await middleware(c, async () => { nextCalled = true; });
      assert.equal(resp, undefined);
      assert.ok(nextCalled, "next must be called when payment is valid");
    } finally {
      globalThis.fetch = orig;
    }
  });
});
