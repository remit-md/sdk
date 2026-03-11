/**
 * x402 client middleware for auto-paying HTTP 402 Payment Required responses.
 *
 * x402 is an open payment standard where resource servers return HTTP 402 with
 * a `PAYMENT-REQUIRED` header describing the cost. This module provides a
 * `fetch` wrapper that intercepts those responses, signs an EIP-3009
 * authorization, and retries the request with a `PAYMENT-SIGNATURE` header.
 *
 * Usage:
 *   ```typescript
 *   import { PrivateKeySigner } from "@remitmd/sdk";
 *   import { X402Client } from "@remitmd/sdk/x402";
 *
 *   const signer = new PrivateKeySigner("0x...");
 *   const client = new X402Client({
 *     signer,
 *     address: signer.getAddress(),
 *     maxAutoPayUsdc: 0.10,
 *   });
 *
 *   const response = await client.fetch("https://api.provider.com/v1/data");
 *   ```
 */

import { randomBytes } from "node:crypto";
import type { Signer } from "./signer.js";

/** EIP-712 type definitions for USDC's transferWithAuthorization (EIP-3009). */
const EIP3009_TYPES = {
  TransferWithAuthorization: [
    { name: "from", type: "address" },
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "validAfter", type: "uint256" },
    { name: "validBefore", type: "uint256" },
    { name: "nonce", type: "bytes32" },
  ],
} as const;

/** Raised when an x402 payment amount exceeds the configured auto-pay limit. */
export class AllowanceExceededError extends Error {
  readonly amountUsdc: number;
  readonly limitUsdc: number;

  constructor(amountUsdc: number, limitUsdc: number) {
    super(
      `x402 payment ${amountUsdc.toFixed(6)} USDC exceeds auto-pay limit ${limitUsdc.toFixed(6)} USDC`,
    );
    this.name = "AllowanceExceededError";
    this.amountUsdc = amountUsdc;
    this.limitUsdc = limitUsdc;
  }
}

/** Configuration for {@link X402Client}. */
export interface X402ClientOptions {
  /** Signer used for EIP-3009 authorization signatures. */
  signer: Signer;
  /** Checksummed payer address — must match the signer's public key. */
  address: string;
  /** Maximum USDC amount to auto-pay per request (default: 0.10). */
  maxAutoPayUsdc?: number;
}

/** Shape of the base64-decoded PAYMENT-REQUIRED header. */
interface PaymentRequired {
  scheme: string;
  network: string;
  amount: string;
  asset: string;
  payTo: string;
  maxTimeoutSeconds?: number;
}

/**
 * `fetch` wrapper that auto-handles HTTP 402 Payment Required responses.
 *
 * On receiving a 402, the client:
 * 1. Decodes the `PAYMENT-REQUIRED` header (base64 JSON)
 * 2. Checks the amount is within `maxAutoPayUsdc`
 * 3. Builds and signs an EIP-3009 `transferWithAuthorization`
 * 4. Base64-encodes the `PAYMENT-SIGNATURE` header
 * 5. Retries the original request with payment attached
 */
export class X402Client {
  readonly #signer: Signer;
  readonly #address: string;
  readonly #maxAutoPayUsdc: number;

  constructor({ signer, address, maxAutoPayUsdc = 0.1 }: X402ClientOptions) {
    this.#signer = signer;
    this.#address = address;
    this.#maxAutoPayUsdc = maxAutoPayUsdc;
  }

  /** Make a fetch request, auto-paying any 402 responses within the configured limit. */
  async fetch(url: string, init?: RequestInit): Promise<Response> {
    const response = await globalThis.fetch(url, init);
    if (response.status === 402) {
      return this.#handle402(url, response, init);
    }
    return response;
  }

  async #handle402(url: string, response: Response, init?: RequestInit): Promise<Response> {
    // 1. Decode PAYMENT-REQUIRED header (header names are case-insensitive per HTTP spec).
    const raw = response.headers.get("payment-required");
    if (!raw) {
      throw new Error("402 response missing PAYMENT-REQUIRED header");
    }
    const required = JSON.parse(Buffer.from(raw, "base64").toString("utf8")) as PaymentRequired;

    // 2. Only the "exact" scheme is supported in V5.
    if (required.scheme !== "exact") {
      throw new Error(`Unsupported x402 scheme: ${required.scheme}`);
    }

    // 3. Check auto-pay limit.
    const amountBaseUnits = BigInt(required.amount);
    const amountUsdc = Number(amountBaseUnits) / 1_000_000;
    if (amountUsdc > this.#maxAutoPayUsdc) {
      throw new AllowanceExceededError(amountUsdc, this.#maxAutoPayUsdc);
    }

    // 4. Parse chainId from CAIP-2 network string (e.g. "eip155:84532" → 84532).
    const chainId = parseInt(required.network.split(":")[1]!, 10);

    // 5. Build EIP-3009 authorization fields.
    const nowSecs = Math.floor(Date.now() / 1000);
    const validBefore = nowSecs + (required.maxTimeoutSeconds ?? 60);
    const nonce = `0x${randomBytes(32).toString("hex")}` as `0x${string}`;

    const domain = {
      name: "USD Coin",
      version: "2",
      chainId,
      verifyingContract: required.asset as `0x${string}`,
    };

    // viem requires uint256 values as bigint.
    const message = {
      from: this.#address as `0x${string}`,
      to: required.payTo as `0x${string}`,
      value: amountBaseUnits,
      validAfter: BigInt(0),
      validBefore: BigInt(validBefore),
      nonce,
    };

    // 6. Sign EIP-712 typed data.
    const signature = await this.#signer.signTypedData(
      domain,
      // Cast: EIP3009_TYPES satisfies TypedDataTypes but has readonly arrays.
      EIP3009_TYPES as unknown as Record<string, Array<{ name: string; type: string }>>,
      message as unknown as Record<string, unknown>,
    );

    // 7. Build PAYMENT-SIGNATURE JSON payload.
    const paymentPayload = {
      scheme: required.scheme,
      network: required.network,
      x402Version: 1,
      payload: {
        signature,
        authorization: {
          from: this.#address,
          to: required.payTo,
          value: required.amount, // string (base units)
          validAfter: "0",
          validBefore: String(validBefore),
          nonce,
        },
      },
    };
    const paymentHeader = Buffer.from(JSON.stringify(paymentPayload)).toString("base64");

    // 8. Retry with PAYMENT-SIGNATURE header.
    const newHeaders = new Headers(init?.headers);
    newHeaders.set("PAYMENT-SIGNATURE", paymentHeader);
    return globalThis.fetch(url, { ...init, headers: newHeaders });
  }

  /** Prevent address leakage via structured cloning / serialisation. */
  toJSON(): Record<string, string> {
    return { address: this.#address };
  }
}
