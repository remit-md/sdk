/**
 * Authenticated HTTP client.
 * - Signs every request with EIP-712 (method, path, timestamp, nonce)
 * - Auto-retry with exponential backoff on 429 and 5xx (up to 3 retries)
 * - Adds idempotency key header on all POST/PATCH/PUT requests
 * - Maps API error codes to typed RemitError subclasses
 */

import { randomBytes } from "node:crypto";
import { fromErrorCode, NetworkError, RateLimitedError } from "./errors.js";
import type { Signer } from "./signer.js";

const EIP712_DOMAIN = {
  name: "remit.md",
  version: "0.1",
} as const;

const EIP712_TYPES = {
  Request: [
    { name: "method", type: "string" },
    { name: "path", type: "string" },
    { name: "timestamp", type: "uint256" },
    { name: "nonce", type: "string" },
  ],
} as const;

interface ApiErrorBody {
  error?: { code?: string; message?: string };
  code?: string;
  message?: string;
}

function newNonce(): string {
  return randomBytes(16).toString("hex");
}

function newIdempotencyKey(): string {
  return randomBytes(16).toString("hex");
}

const RETRYABLE = new Set([429, 500, 502, 503, 504]);
const DELAY_MS = [200, 600, 1800]; // exponential-ish

async function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export interface HttpClientOptions {
  signer: Signer;
  baseUrl: string;
}

export class AuthenticatedClient {
  readonly #signer: Signer;
  readonly #baseUrl: string;

  constructor({ signer, baseUrl }: HttpClientOptions) {
    this.#signer = signer;
    this.#baseUrl = baseUrl.replace(/\/$/, "");
  }

  async get<T>(path: string): Promise<T> {
    return this.#request<T>("GET", path);
  }

  async post<T>(path: string, body?: unknown): Promise<T> {
    return this.#request<T>("POST", path, body);
  }

  async put<T>(path: string, body?: unknown): Promise<T> {
    return this.#request<T>("PUT", path, body);
  }

  async delete<T>(path: string): Promise<T> {
    return this.#request<T>("DELETE", path);
  }

  async #request<T>(method: string, path: string, body?: unknown, attempt = 0): Promise<T> {
    const timestamp = Math.floor(Date.now() / 1000);
    const nonce = newNonce();

    // Sign the request metadata (never body — body may be large)
    const signature = await this.#signer.signTypedData(
      EIP712_DOMAIN,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      EIP712_TYPES as any,
      { method, path, timestamp: BigInt(timestamp), nonce },
    );

    const headers: Record<string, string> = {
      "Content-Type": "application/json",
      "X-Remit-Address": this.#signer.getAddress(),
      "X-Remit-Signature": signature,
      "X-Remit-Timestamp": String(timestamp),
      "X-Remit-Nonce": nonce,
    };

    if (method === "POST" || method === "PUT" || method === "PATCH") {
      headers["Idempotency-Key"] = newIdempotencyKey();
    }

    let response: Response;
    try {
      response = await fetch(`${this.#baseUrl}${path}`, {
        method,
        headers,
        body: body !== undefined ? JSON.stringify(body) : undefined,
      });
    } catch (err) {
      throw new NetworkError(`Network request failed: ${String(err)}`);
    }

    if (response.ok) {
      if (response.status === 204) return undefined as T;
      return (await response.json()) as T;
    }

    // Retryable errors
    if (RETRYABLE.has(response.status) && attempt < DELAY_MS.length) {
      if (response.status === 429) {
        // Respect Retry-After header if present
        const retryAfter = response.headers.get("Retry-After");
        const delay = retryAfter ? parseInt(retryAfter) * 1000 : DELAY_MS[attempt];
        await sleep(delay);
      } else {
        await sleep(DELAY_MS[attempt]);
      }
      return this.#request<T>(method, path, body, attempt + 1);
    }

    // Parse error body
    let errorBody: ApiErrorBody = {};
    try {
      errorBody = (await response.json()) as ApiErrorBody;
    } catch {
      // ignore parse failures
    }

    const code =
      errorBody.error?.code ?? errorBody.code ?? `HTTP_${response.status}`;
    const message =
      errorBody.error?.message ?? errorBody.message ?? response.statusText;

    if (response.status === 429) throw new RateLimitedError(message);
    throw fromErrorCode(code, message);
  }
}
