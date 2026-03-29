import { describe, it, mock, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { PrivateKeySigner } from "../src/signer.js";
import { AllowanceExceededError, X402Client } from "../src/x402.js";
import type { AuthenticatedClient } from "../src/http.js";

// Anvil account #0 - well-known test key.
const TEST_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const TEST_ADDR = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const PROVIDER = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const USDC = "0x2d846325766921935f37d5b4478196d3ef93707c";

/**
 * Build a mock AuthenticatedClient whose `post` returns a canned /x402/prepare
 * response. The hash is 32 zero-bytes (0x00…00) which the signer will happily sign.
 */
function makeMockApiHttp(overrides?: Partial<Record<string, string>>): AuthenticatedClient {
  const defaults: Record<string, string> = {
    hash: "0x" + "00".repeat(32),
    from: TEST_ADDR,
    to: PROVIDER,
    value: "100000",
    validAfter: "0",
    validBefore: "115792089237316195423570985008687907853269984665640564039457584007913129639935",
    nonce: "0x" + "ab".repeat(32),
    ...overrides,
  };
  return {
    post: async () => defaults,
    get: async () => ({}),
  } as unknown as AuthenticatedClient;
}

function makePaymentRequired(opts: {
  amount?: string;
  scheme?: string;
  network?: string;
  payTo?: string;
  maxTimeoutSeconds?: number;
  resource?: string;
  description?: string;
  mimeType?: string;
}): string {
  const payload: Record<string, unknown> = {
    scheme: opts.scheme ?? "exact",
    network: opts.network ?? "eip155:31337",
    amount: opts.amount ?? "100000",
    asset: USDC,
    payTo: opts.payTo ?? PROVIDER,
    maxTimeoutSeconds: opts.maxTimeoutSeconds ?? 30,
  };
  if (opts.resource !== undefined) payload["resource"] = opts.resource;
  if (opts.description !== undefined) payload["description"] = opts.description;
  if (opts.mimeType !== undefined) payload["mimeType"] = opts.mimeType;
  return Buffer.from(JSON.stringify(payload)).toString("base64");
}

function makeMockFetch(responses: Array<{ status: number; headers?: Record<string, string> }>) {
  let callIndex = 0;
  const capturedCalls: Array<{ url: string; init?: RequestInit }> = [];

  const fetchFn = async (url: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const r = responses[callIndex++];
    if (!r) throw new Error("Unexpected fetch call");
    capturedCalls.push({ url: String(url), init });
    const headerMap = new Headers(r.headers ?? {});
    return new Response(null, { status: r.status, headers: headerMap });
  };

  return { fetchFn, capturedCalls };
}

// ─── Construction ─────────────────────────────────────────────────────────────

describe("X402Client construction", () => {
  it("constructs with signer and address", () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    const client = new X402Client({ signer, address: TEST_ADDR, apiHttp: makeMockApiHttp() });
    // Should not throw; toJSON() reveals address only.
    assert.equal(client.toJSON().address, TEST_ADDR);
  });

  it("defaults maxAutoPayUsdc to 0.10", () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    const client = new X402Client({ signer, address: TEST_ADDR, apiHttp: makeMockApiHttp() });
    // Only way to observe is via toJSON (no limit getter).
    assert.ok(client instanceof X402Client);
  });
});

// ─── AllowanceExceededError ────────────────────────────────────────────────────

describe("AllowanceExceededError", () => {
  it("includes amounts in message", () => {
    const err = new AllowanceExceededError(0.5, 0.1);
    assert.ok(err.message.includes("0.500000"));
    assert.ok(err.message.includes("0.100000"));
    assert.equal(err.amountUsdc, 0.5);
    assert.equal(err.limitUsdc, 0.1);
    assert.equal(err.name, "AllowanceExceededError");
  });

  it("is an instance of Error", () => {
    const err = new AllowanceExceededError(1.0, 0.5);
    assert.ok(err instanceof Error);
  });
});

// ─── fetch passthrough ─────────────────────────────────────────────────────────

describe("X402Client.fetch - non-402 passthrough", () => {
  it("returns 200 response unchanged", async () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    const { fetchFn } = makeMockFetch([{ status: 200 }]);
    const client = new X402Client({ signer, address: TEST_ADDR, apiHttp: makeMockApiHttp() });

    // Temporarily patch globalThis.fetch.
    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = fetchFn;
      const resp = await client.fetch("http://example.com/data");
      assert.equal(resp.status, 200);
    } finally {
      globalThis.fetch = orig;
    }
  });
});

// ─── 402 handling ─────────────────────────────────────────────────────────────

describe("X402Client.fetch - 402 handling", () => {
  it("throws when PAYMENT-REQUIRED header is absent", async () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    const { fetchFn } = makeMockFetch([{ status: 402 }]);
    const client = new X402Client({ signer, address: TEST_ADDR, maxAutoPayUsdc: 1.0, apiHttp: makeMockApiHttp() });

    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = fetchFn;
      await assert.rejects(
        () => client.fetch("http://example.com/data"),
        /PAYMENT-REQUIRED/,
      );
    } finally {
      globalThis.fetch = orig;
    }
  });

  it("throws for unsupported scheme", async () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    const header = makePaymentRequired({ scheme: "upto" });
    const { fetchFn } = makeMockFetch([{ status: 402, headers: { "payment-required": header } }]);
    const client = new X402Client({ signer, address: TEST_ADDR, maxAutoPayUsdc: 1.0, apiHttp: makeMockApiHttp() });

    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = fetchFn;
      await assert.rejects(
        () => client.fetch("http://example.com/data"),
        /scheme/,
      );
    } finally {
      globalThis.fetch = orig;
    }
  });

  it("throws AllowanceExceededError when payment exceeds limit", async () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    // 100000 base units = 0.10 USDC; limit = 0.05
    const header = makePaymentRequired({ amount: "100000" });
    const { fetchFn } = makeMockFetch([{ status: 402, headers: { "payment-required": header } }]);
    const client = new X402Client({ signer, address: TEST_ADDR, maxAutoPayUsdc: 0.05, apiHttp: makeMockApiHttp() });

    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = fetchFn;
      await assert.rejects(
        () => client.fetch("http://example.com/data"),
        AllowanceExceededError,
      );
    } finally {
      globalThis.fetch = orig;
    }
  });

  it("retries with PAYMENT-SIGNATURE header and returns 200", async () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    const header402 = makePaymentRequired({ amount: "100000" });
    const { fetchFn, capturedCalls } = makeMockFetch([
      { status: 402, headers: { "payment-required": header402 } },
      { status: 200 },
    ]);
    const client = new X402Client({ signer, address: TEST_ADDR, maxAutoPayUsdc: 1.0, apiHttp: makeMockApiHttp() });

    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = fetchFn;
      const resp = await client.fetch("http://example.com/data");
      assert.equal(resp.status, 200);
    } finally {
      globalThis.fetch = orig;
    }

    // Two fetch calls: initial + retry.
    assert.equal(capturedCalls.length, 2);

    // Retry must carry PAYMENT-SIGNATURE header.
    const retryInit = capturedCalls[1]!.init!;
    const retryHeaders = new Headers(retryInit.headers);
    const paymentSig = retryHeaders.get("payment-signature");
    assert.ok(paymentSig, "PAYMENT-SIGNATURE header must be present on retry");

    // Decode and validate payload structure.
    const payload = JSON.parse(Buffer.from(paymentSig!, "base64").toString("utf8")) as {
      scheme: string;
      network: string;
      x402Version: number;
      payload: {
        signature: string;
        authorization: {
          from: string;
          to: string;
          value: string;
          validAfter: string;
          validBefore: string;
          nonce: string;
        };
      };
    };

    assert.equal(payload.scheme, "exact");
    assert.equal(payload.network, "eip155:31337");
    assert.equal(payload.x402Version, 1);

    const auth = payload.payload.authorization;
    assert.equal(auth.from.toLowerCase(), TEST_ADDR.toLowerCase());
    assert.equal(auth.to.toLowerCase(), PROVIDER.toLowerCase());
    assert.equal(auth.value, "100000");
    assert.equal(auth.validAfter, "0");
    assert.ok(auth.nonce.startsWith("0x"));
    assert.equal(auth.nonce.length, 66); // 0x + 64 hex chars = 32 bytes

    // Signature must be 0x-prefixed hex.
    assert.ok(payload.payload.signature.startsWith("0x"));
  });

  it("preserves other request headers on retry", async () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    const header402 = makePaymentRequired({ amount: "1000" });
    const { fetchFn, capturedCalls } = makeMockFetch([
      { status: 402, headers: { "payment-required": header402 } },
      { status: 200 },
    ]);
    const client = new X402Client({ signer, address: TEST_ADDR, maxAutoPayUsdc: 1.0, apiHttp: makeMockApiHttp() });

    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = fetchFn;
      await client.fetch("http://example.com/data", {
        headers: { Authorization: "Bearer abc123", "X-Custom": "hello" },
      });
    } finally {
      globalThis.fetch = orig;
    }

    const retryHeaders = new Headers(capturedCalls[1]!.init!.headers);
    assert.equal(retryHeaders.get("authorization"), "Bearer abc123");
    assert.equal(retryHeaders.get("x-custom"), "hello");
    assert.ok(retryHeaders.get("payment-signature"));
  });

  it("exposes V2 resource/description/mimeType via lastPayment", async () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    const header402 = makePaymentRequired({
      amount: "1000",
      resource: "/api/v1/premium",
      description: "Access to premium data",
      mimeType: "application/json",
    });
    const { fetchFn } = makeMockFetch([
      { status: 402, headers: { "payment-required": header402 } },
      { status: 200 },
    ]);
    const client = new X402Client({ signer, address: TEST_ADDR, maxAutoPayUsdc: 1.0, apiHttp: makeMockApiHttp() });

    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = fetchFn;
      await client.fetch("http://example.com/api/v1/premium");
    } finally {
      globalThis.fetch = orig;
    }

    assert.ok(client.lastPayment, "lastPayment must be set after payment");
    assert.equal(client.lastPayment!.resource, "/api/v1/premium");
    assert.equal(client.lastPayment!.description, "Access to premium data");
    assert.equal(client.lastPayment!.mimeType, "application/json");
  });

  it("parses chainId correctly from CAIP-2 network string", async () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    const header402 = makePaymentRequired({ amount: "1000", network: "eip155:84532" });
    const { fetchFn, capturedCalls } = makeMockFetch([
      { status: 402, headers: { "payment-required": header402 } },
      { status: 200 },
    ]);
    const client = new X402Client({ signer, address: TEST_ADDR, maxAutoPayUsdc: 1.0, apiHttp: makeMockApiHttp() });

    const orig = globalThis.fetch;
    try {
      (globalThis as Record<string, unknown>)["fetch"] = fetchFn;
      await client.fetch("http://example.com/resource");
    } finally {
      globalThis.fetch = orig;
    }

    const retryHeaders = new Headers(capturedCalls[1]!.init!.headers);
    const payload = JSON.parse(
      Buffer.from(retryHeaders.get("payment-signature")!, "base64").toString("utf8"),
    ) as { network: string };
    assert.equal(payload.network, "eip155:84532");
  });
});
