/**
 * x402 client middleware for auto-paying HTTP 402 Payment Required responses.
 *
 * x402 is an open payment standard where resource servers return HTTP 402 with
 * a `PAYMENT-REQUIRED` header describing the cost. This module provides a
 * `fetch` wrapper that intercepts those responses, calls the server's
 * `/x402/prepare` endpoint for hash + authorization fields, signs the hash,
 * and retries the request with a `PAYMENT-SIGNATURE` header.
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
 *     apiHttp: authenticatedClient,
 *   });
 *
 *   const response = await client.fetch("https://api.provider.com/v1/data");
 *   ```
 */

import type { Signer } from "./signer.js";
import type { AuthenticatedClient } from "./http.js";

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
  /** Signer used for hash signing. */
  signer: Signer;
  /** Checksummed payer address - must match the signer's public key. */
  address: string;
  /** Maximum USDC amount to auto-pay per request (default: 0.10). */
  maxAutoPayUsdc?: number;
  /** Authenticated HTTP client for calling /x402/prepare. */
  apiHttp: AuthenticatedClient;
}

/** Shape of the base64-decoded PAYMENT-REQUIRED header (V2). */
export interface PaymentRequired {
  scheme: string;
  network: string;
  amount: string;
  asset: string;
  payTo: string;
  maxTimeoutSeconds?: number;
  // V2 optional fields - informational metadata about the resource being paid for.
  /** URL or path of the resource being protected (e.g. "/api/v1/data"). */
  resource?: string;
  /** Human-readable description of what the payment is for. */
  description?: string;
  /** MIME type of the resource (e.g. "application/json"). */
  mimeType?: string;
}

/**
 * `fetch` wrapper that auto-handles HTTP 402 Payment Required responses.
 *
 * On receiving a 402, the client:
 * 1. Decodes the `PAYMENT-REQUIRED` header (base64 JSON)
 * 2. Checks the amount is within `maxAutoPayUsdc`
 * 3. Calls `/x402/prepare` to get hash + authorization fields
 * 4. Signs the hash
 * 5. Base64-encodes the `PAYMENT-SIGNATURE` header
 * 6. Retries the original request with payment attached
 *
 * V2: The decoded `PAYMENT-REQUIRED` may include `resource`, `description`,
 * and `mimeType` fields. Access the last payment via `lastPayment`.
 */
export class X402Client {
  readonly #signer: Signer;
  readonly #address: string;
  readonly #maxAutoPayUsdc: number;
  readonly #apiHttp: AuthenticatedClient;
  /** The last PAYMENT-REQUIRED decoded before payment. Useful for logging/display. */
  lastPayment: PaymentRequired | null = null;

  constructor({ signer, address, maxAutoPayUsdc = 0.1, apiHttp }: X402ClientOptions) {
    this.#signer = signer;
    this.#address = address;
    this.#maxAutoPayUsdc = maxAutoPayUsdc;
    this.#apiHttp = apiHttp;
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

    // 2. Only the "exact" scheme is supported.
    if (required.scheme !== "exact") {
      throw new Error(`Unsupported x402 scheme: ${required.scheme}`);
    }

    // Store for caller inspection (V2 fields: resource, description, mimeType).
    this.lastPayment = required;

    // 3. Check auto-pay limit.
    const amountBaseUnits = BigInt(required.amount);
    const amountUsdc = Number(amountBaseUnits) / 1_000_000;
    if (amountUsdc > this.#maxAutoPayUsdc) {
      throw new AllowanceExceededError(amountUsdc, this.#maxAutoPayUsdc);
    }

    // 4. Call /x402/prepare to get the hash + authorization fields.
    const prepareData = await this.#apiHttp.post<Record<string, string>>("/x402/prepare", {
      payment_required: raw,
      payer: this.#address,
    });

    // 5. Sign the hash.
    const hashHex = prepareData.hash;
    const hashBytes = new Uint8Array(
      (hashHex.startsWith("0x") ? hashHex.slice(2) : hashHex)
        .match(/.{2}/g)!
        .map((b) => parseInt(b, 16)),
    );
    const signature = await this.#signer.signHash(hashBytes);

    // 6. Build PAYMENT-SIGNATURE JSON payload.
    const paymentPayload = {
      scheme: required.scheme,
      network: required.network,
      x402Version: 1,
      payload: {
        signature,
        authorization: {
          from: prepareData.from,
          to: prepareData.to,
          value: prepareData.value,
          validAfter: prepareData.validAfter,
          validBefore: prepareData.validBefore,
          nonce: prepareData.nonce,
        },
      },
    };
    const paymentHeader = Buffer.from(JSON.stringify(paymentPayload)).toString("base64");

    // 7. Retry with PAYMENT-SIGNATURE header.
    const newHeaders = new Headers(init?.headers);
    newHeaders.set("PAYMENT-SIGNATURE", paymentHeader);
    return globalThis.fetch(url, { ...init, headers: newHeaders });
  }

  /** Prevent address leakage via structured cloning / serialisation. */
  toJSON(): Record<string, string> {
    return { address: this.#address };
  }
}
