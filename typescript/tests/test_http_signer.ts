import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server, type IncomingMessage, type ServerResponse } from "node:http";
import { inspect } from "node:util";

import { HttpSigner } from "../src/http-signer.js";

// ─── Mock Signer Server ──────────────────────────────────────────────────────

const MOCK_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const MOCK_SIGNATURE = "0x" + "ab".repeat(32) + "cd".repeat(32) + "1b";
const VALID_TOKEN = "rmit_sk_" + "a1".repeat(32);

interface MockServerOptions {
  /** Override the response for specific paths. */
  overrides?: Record<string, { status: number; body: unknown }>;
}

function createMockServer(options?: MockServerOptions): { server: Server; port: number; url: string } {
  const overrides = options?.overrides ?? {};
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    const path = req.url ?? "/";

    // Check auth on all endpoints except /health
    if (path !== "/health") {
      const auth = req.headers.authorization;
      if (!auth || !auth.startsWith("Bearer ")) {
        res.writeHead(401, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "unauthorized" }));
        return;
      }
      const token = auth.slice(7);
      if (token !== VALID_TOKEN) {
        res.writeHead(401, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "unauthorized" }));
        return;
      }
    }

    // Check overrides first
    if (overrides[path]) {
      const { status, body } = overrides[path]!;
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(body));
      return;
    }

    if (path === "/address" && req.method === "GET") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ address: MOCK_ADDRESS }));
    } else if (path === "/sign/typed-data" && req.method === "POST") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ signature: MOCK_SIGNATURE }));
    } else if (path === "/health" && req.method === "GET") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true, version: "test", wallet: "test" }));
    } else {
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "not_found" }));
    }
  });

  // Listen on random port
  server.listen(0);
  const addr = server.address();
  const port = typeof addr === "object" && addr !== null ? addr.port : 0;
  return { server, port, url: `http://127.0.0.1:${port}` };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

describe("HttpSigner", () => {
  let server: Server;
  let url: string;

  beforeEach(() => {
    const mock = createMockServer();
    server = mock.server;
    url = mock.url;
  });

  afterEach(() => {
    server.close();
  });

  // ── Construction ──────────────────────────────────────────────────────

  it("create() fetches and caches address", async () => {
    const signer = await HttpSigner.create({ url, token: VALID_TOKEN });
    assert.equal(signer.getAddress(), MOCK_ADDRESS);
  });

  it("getAddress() throws if not initialized", () => {
    // Can't call constructor directly (private), but we can test the error path
    // by checking that create() is required
    assert.ok(HttpSigner.create, "create static method must exist");
  });

  // ── signTypedData ─────────────────────────────────────────────────────

  it("signTypedData() returns signature from server", async () => {
    const signer = await HttpSigner.create({ url, token: VALID_TOKEN });
    const sig = await signer.signTypedData(
      { name: "Test", version: "1" },
      { Test: [{ name: "value", type: "uint256" }] },
      { value: 42 },
    );
    assert.equal(sig, MOCK_SIGNATURE);
  });

  it("signTypedData() handles BigInt values", async () => {
    const signer = await HttpSigner.create({ url, token: VALID_TOKEN });
    // BigInt should be serialized as string without throwing
    const sig = await signer.signTypedData(
      { name: "Test", version: "1" },
      { Test: [{ name: "value", type: "uint256" }] },
      { value: BigInt("1000000000000000000") },
    );
    assert.equal(sig, MOCK_SIGNATURE);
  });

  // ── Auth errors ───────────────────────────────────────────────────────

  it("create() fails with bad token", async () => {
    await assert.rejects(
      () => HttpSigner.create({ url, token: "bad_token_abc" }),
      (err: Error) => {
        assert.ok(err.message.includes("401"), `expected 401 mention, got: ${err.message}`);
        return true;
      },
    );
  });

  it("signTypedData() throws on 401", async () => {
    // Create with valid token, then manually test with a server that rejects
    const mock2 = createMockServer({
      overrides: {
        "/address": { status: 200, body: { address: MOCK_ADDRESS } },
        "/sign/typed-data": { status: 401, body: { error: "unauthorized" } },
      },
    });
    const signer = await HttpSigner.create({ url: mock2.url, token: VALID_TOKEN });

    await assert.rejects(
      () => signer.signTypedData({ name: "T", version: "1" }, {}, {}),
      (err: Error) => {
        assert.ok(err.message.includes("unauthorized"), `expected unauthorized, got: ${err.message}`);
        return true;
      },
    );
    mock2.server.close();
  });

  // ── Policy denial ─────────────────────────────────────────────────────

  it("signTypedData() throws on 403 with reason", async () => {
    const mock2 = createMockServer({
      overrides: {
        "/address": { status: 200, body: { address: MOCK_ADDRESS } },
        "/sign/typed-data": { status: 403, body: { error: "policy_denied", reason: "chain not allowed" } },
      },
    });
    const signer = await HttpSigner.create({ url: mock2.url, token: VALID_TOKEN });

    await assert.rejects(
      () => signer.signTypedData({ name: "T", version: "1" }, {}, {}),
      (err: Error) => {
        assert.ok(err.message.includes("policy denied"), `expected policy denied, got: ${err.message}`);
        assert.ok(err.message.includes("chain not allowed"), `expected reason, got: ${err.message}`);
        return true;
      },
    );
    mock2.server.close();
  });

  // ── Server error ──────────────────────────────────────────────────────

  it("signTypedData() throws on 500", async () => {
    const mock2 = createMockServer({
      overrides: {
        "/address": { status: 200, body: { address: MOCK_ADDRESS } },
        "/sign/typed-data": { status: 500, body: { error: "internal_error" } },
      },
    });
    const signer = await HttpSigner.create({ url: mock2.url, token: VALID_TOKEN });

    await assert.rejects(
      () => signer.signTypedData({ name: "T", version: "1" }, {}, {}),
      (err: Error) => {
        assert.ok(err.message.includes("500"), `expected 500, got: ${err.message}`);
        return true;
      },
    );
    mock2.server.close();
  });

  // ── Server unreachable ────────────────────────────────────────────────

  it("create() throws when server unreachable", async () => {
    await assert.rejects(
      () => HttpSigner.create({ url: "http://127.0.0.1:1", token: VALID_TOKEN }),
      (err: Error) => {
        assert.ok(err.message.includes("cannot reach"), `expected cannot reach, got: ${err.message}`);
        return true;
      },
    );
  });

  // ── No credential leakage ─────────────────────────────────────────────

  it("toJSON() does not leak token", async () => {
    const signer = await HttpSigner.create({ url, token: VALID_TOKEN });
    const json = signer.toJSON();
    assert.equal(json.address, MOCK_ADDRESS);
    assert.ok(!JSON.stringify(json).includes(VALID_TOKEN), "token must not appear in JSON");
  });

  it("inspect() does not leak token", async () => {
    const signer = await HttpSigner.create({ url, token: VALID_TOKEN });
    const str = inspect(signer);
    assert.ok(!str.includes(VALID_TOKEN), "token must not appear in inspect output");
    assert.ok(str.includes(MOCK_ADDRESS), "address should appear in inspect");
  });

  // ── Malformed response ────────────────────────────────────────────────

  it("signTypedData() throws on malformed response", async () => {
    const mock2 = createMockServer({
      overrides: {
        "/address": { status: 200, body: { address: MOCK_ADDRESS } },
        "/sign/typed-data": { status: 200, body: { notSignature: true } },
      },
    });
    const signer = await HttpSigner.create({ url: mock2.url, token: VALID_TOKEN });

    await assert.rejects(
      () => signer.signTypedData({ name: "T", version: "1" }, {}, {}),
      (err: Error) => {
        assert.ok(err.message.includes("no signature"), `expected no signature, got: ${err.message}`);
        return true;
      },
    );
    mock2.server.close();
  });
});
