/**
 * SDK acceptance: x402 auto-payment via wallet.x402Fetch().
 *
 * Spins up a local test server that returns 402 with a PAYMENT-REQUIRED header.
 * The SDK's x402Fetch() auto-signs EIP-3009 and retries with PAYMENT-SIGNATURE.
 * We verify the payment signature is structurally valid and the retry succeeds.
 *
 * On-chain settlement is tested separately in the API acceptance tests (C2).
 * This test focuses on the SDK client-side flow: 402 detection → EIP-3009 signing → retry.
 */

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { Wallet } from "../../src/wallet.js";
import { createWallet, fundWallet, API_URL } from "./setup.js";

describe("SDK: x402 Auto-Payment", { timeout: 120_000 }, () => {
  let agent: Wallet;
  let server: Server;
  let serverUrl: string;

  /** Fetch contracts to get USDC + Router addresses for the paywall header. */
  async function getContractAddrs(): Promise<{ usdc: string; router: string }> {
    const res = await fetch(`${API_URL}/contracts`);
    const data = (await res.json()) as { usdc: string; router: string };
    return data;
  }

  before(async () => {
    agent = await createWallet();
    await fundWallet(agent, 100);

    const contracts = await getContractAddrs();

    // Create a local x402 paywall server
    server = createServer((req, res) => {
      const paymentSig = req.headers["payment-signature"];

      if (!paymentSig) {
        // First request: return 402 with payment requirements
        const paymentRequired = {
          scheme: "exact",
          network: "eip155:84532",
          amount: "100000", // $0.10 USDC (within default maxAutoPayUsdc)
          asset: contracts.usdc,
          payTo: contracts.router,
          maxTimeoutSeconds: 60,
          resource: "/test-resource",
          description: "x402 acceptance test",
          mimeType: "text/plain",
        };
        const encoded = Buffer.from(JSON.stringify(paymentRequired)).toString("base64");
        res.writeHead(402, {
          "Content-Type": "text/plain",
          "payment-required": encoded,
        });
        res.end("Payment Required");
        return;
      }

      // Second request: has PAYMENT-SIGNATURE - validate structure then return 200
      try {
        const decoded = JSON.parse(
          Buffer.from(paymentSig as string, "base64").toString("utf8"),
        ) as {
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

        // Validate payment structure
        if (decoded.scheme !== "exact") throw new Error("wrong scheme");
        if (decoded.network !== "eip155:84532") throw new Error("wrong network");
        if (!decoded.payload.signature.startsWith("0x")) throw new Error("bad signature");
        if (decoded.payload.authorization.from.toLowerCase() !== agent.address.toLowerCase()) {
          throw new Error("wrong payer");
        }
        if (decoded.payload.authorization.value !== "100000") throw new Error("wrong amount");

        res.writeHead(200, { "Content-Type": "text/plain" });
        res.end("paid content");
      } catch (e) {
        res.writeHead(400);
        res.end(`Invalid payment: ${(e as Error).message}`);
      }
    });

    await new Promise<void>((resolve) => {
      server.listen(0, "127.0.0.1", () => {
        const addr = server.address() as { port: number };
        serverUrl = `http://127.0.0.1:${addr.port}`;
        resolve();
      });
    });
  });

  after(() => {
    server?.close();
  });

  it("x402Fetch auto-pays 402 and returns 200 with content", async () => {
    const { response, lastPayment } = await agent.x402Fetch(`${serverUrl}/test-resource`);

    assert.equal(response.status, 200, "should get 200 after auto-payment");
    const body = await response.text();
    assert.equal(body, "paid content", "should receive paid content");

    // Verify lastPayment metadata (V2 fields)
    assert.ok(lastPayment, "lastPayment should be set");
    assert.equal(lastPayment.scheme, "exact");
    assert.equal(lastPayment.amount, "100000");
    assert.equal(lastPayment.resource, "/test-resource");
    assert.equal(lastPayment.description, "x402 acceptance test");
    assert.equal(lastPayment.mimeType, "text/plain");
  });

  it("x402Fetch rejects payment above maxAutoPayUsdc", async () => {
    // The default limit is $0.10, and the paywall asks for $0.10 - right at the edge.
    // Test with a lower limit ($0.01) to verify rejection.
    await assert.rejects(
      () => agent.x402Fetch(`${serverUrl}/test-resource`, 0.01),
      (err: Error) => {
        assert.ok(err.message.includes("exceeds auto-pay limit"), `wrong error: ${err.message}`);
        return true;
      },
    );
  });
});
