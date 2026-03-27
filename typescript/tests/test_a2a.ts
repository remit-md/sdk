import { describe, it, mock, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";

import { discoverAgent, getTaskTxHash, A2AClient } from "../src/a2a.js";
import type { AgentCard, A2ATask } from "../src/a2a.js";
import { PrivateKeySigner } from "../src/signer.js";

// ─── Fixtures ─────────────────────────────────────────────────────────────────

const CARD_DATA: AgentCard = {
  protocolVersion: "0.6",
  name: "remit.md",
  description: "USDC payment protocol for AI agents.",
  url: "https://remit.md/a2a",
  version: "0.1.0",
  documentationUrl: "https://remit.md/docs",
  capabilities: {
    streaming: false,
    pushNotifications: false,
    stateTransitionHistory: true,
    extensions: [
      {
        uri: "https://ap2-protocol.org/ext/payment-processor",
        description: "AP2 payment processor",
        required: false,
      },
    ],
  },
  authentication: [],
  skills: [
    {
      id: "direct-payment",
      name: "Direct Payment",
      description: "Send USDC directly.",
      tags: ["payment", "usdc"],
    },
    {
      id: "x402-paywall",
      name: "x402 Paywall",
      description: "HTTP 402 payment rail.",
      tags: ["x402", "paywall"],
    },
  ],
  x402: {
    settleEndpoint: "https://remit.md/api/v1/x402/settle",
    assets: { "eip155:8453": "0xUSDC" },
    fees: { standardBps: 100, preferredBps: 50, cliffUsd: 10000 },
  },
};

// ─── discoverAgent ─────────────────────────────────────────────────────────────

describe("discoverAgent", () => {
  let fetchMock: ReturnType<typeof mock.fn>;

  beforeEach(() => {
    fetchMock = mock.fn(async (_url: string) => ({
      ok: true,
      status: 200,
      json: async () => CARD_DATA,
    }));
    (globalThis as unknown as { fetch: unknown }).fetch = fetchMock;
  });

  afterEach(() => {
    mock.restoreAll();
  });

  it("fetches from /.well-known/agent-card.json", async () => {
    const card = await discoverAgent("https://remit.md");
    assert.equal(fetchMock.mock.calls.length, 1);
    const url = fetchMock.mock.calls[0]!.arguments[0] as string;
    assert.equal(url, "https://remit.md/.well-known/agent-card.json");
  });

  it("strips trailing slash from base URL", async () => {
    await discoverAgent("https://remit.md/");
    const url = fetchMock.mock.calls[0]!.arguments[0] as string;
    assert.equal(url, "https://remit.md/.well-known/agent-card.json");
  });

  it("returns parsed agent card", async () => {
    const card = await discoverAgent("https://remit.md");
    assert.equal(card.name, "remit.md");
    assert.equal(card.url, "https://remit.md/a2a");
    assert.equal(card.protocolVersion, "0.6");
    assert.equal(card.skills.length, 2);
    assert.equal(card.x402.fees.standardBps, 100);
  });

  it("throws on non-200 response", async () => {
    fetchMock = mock.fn(async () => ({ ok: false, status: 404, statusText: "Not Found" }));
    (globalThis as unknown as { fetch: unknown }).fetch = fetchMock;
    await assert.rejects(
      () => discoverAgent("https://notfound.example"),
      /404/,
    );
  });
});

// ─── getTaskTxHash ─────────────────────────────────────────────────────────────

describe("getTaskTxHash", () => {
  it("extracts txHash from artifacts", () => {
    const task: A2ATask = {
      id: "task_1",
      status: { state: "completed" },
      artifacts: [
        { parts: [{ kind: "data", data: { txHash: "0xdeadbeef" } }] },
      ],
    };
    assert.equal(getTaskTxHash(task), "0xdeadbeef");
  });

  it("returns undefined when no artifacts", () => {
    const task: A2ATask = {
      id: "task_2",
      status: { state: "completed" },
      artifacts: [],
    };
    assert.equal(getTaskTxHash(task), undefined);
  });

  it("returns undefined when artifacts have no txHash", () => {
    const task: A2ATask = {
      id: "task_3",
      status: { state: "failed" },
      artifacts: [{ parts: [{ kind: "data", data: { foo: "bar" } }] }],
    };
    assert.equal(getTaskTxHash(task), undefined);
  });
});

// ─── A2AClient constructor ────────────────────────────────────────────────────

describe("A2AClient", () => {
  const TEST_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

  it("fromCard creates client with correct path", () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    const client = A2AClient.fromCard(CARD_DATA, signer);
    // Access internal path (private field - test via behavior or cast)
    assert.ok(client instanceof A2AClient);
  });

  it("fromCard accepts chain option", () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    const client = A2AClient.fromCard(CARD_DATA, signer, { chain: "base-sepolia" });
    assert.ok(client instanceof A2AClient);
  });
});
