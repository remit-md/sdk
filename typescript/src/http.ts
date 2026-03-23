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

// EIP-712 typed struct definition — must match server's auth.rs exactly.
// Struct name: APIRequest (not Request)
// Timestamp type: uint256 (not uint64 or uint32)
// Nonce type: bytes32 (not string)
const EIP712_TYPES = {
  APIRequest: [
    { name: "method", type: "string" },
    { name: "path", type: "string" },
    { name: "timestamp", type: "uint256" },
    { name: "nonce", type: "bytes32" },
  ],
} as const;

interface ApiErrorBody {
  error?: { code?: string; message?: string };
  code?: string;
  message?: string;
}

/** 32-byte hex nonce with 0x prefix — required for bytes32 EIP-712 field. */
function newNonce(): `0x${string}` {
  return `0x${randomBytes(32).toString("hex")}`;
}

function newIdempotencyKey(): string {
  return randomBytes(16).toString("hex");
}

/** Convert a snake_case key to camelCase (e.g. "tx_hash" → "txHash"). */
function toCamel(key: string): string {
  return key.replace(/_([a-z])/g, (_, c: string) => c.toUpperCase());
}

/** Recursively transform all object keys from snake_case to camelCase.
 *  The server (Rust/serde) emits snake_case; TypeScript SDK uses camelCase. */
function camelizeKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(camelizeKeys);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [toCamel(k), camelizeKeys(v)]),
    );
  }
  return value;
}

const RETRYABLE = new Set([429, 500, 502, 503, 504]);
const DELAY_MS = [200, 600, 1800]; // exponential-ish

async function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export interface HttpClientOptions {
  signer: Signer;
  baseUrl: string;
  chainId: number;
  verifyingContract?: string;
}

export class AuthenticatedClient {
  readonly #signer: Signer;
  readonly #baseUrl: string;
  readonly #chainId: number;
  readonly #verifyingContract: string;
  /** Path prefix extracted from baseUrl (e.g. "/api/v1") to prepend when signing.
   *  The server verifies the full path (/api/v1/payments/direct) via OriginalUri,
   *  not just the relative segment (/payments/direct). */
  readonly #signPathPrefix: string;

  constructor({ signer, baseUrl, chainId, verifyingContract = "" }: HttpClientOptions) {
    this.#signer = signer;
    this.#baseUrl = baseUrl.replace(/\/$/, "");
    this.#chainId = chainId;
    this.#verifyingContract = verifyingContract;
    // Parse path prefix from baseUrl so signed path matches OriginalUri on server.
    const parsedUrl = new URL(this.#baseUrl);
    this.#signPathPrefix = parsedUrl.pathname.replace(/\/$/, "");
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

  async #request<T>(method: string, path: string, body?: unknown, attempt = 0, idempotencyKey?: string): Promise<T> {
    const timestamp = Math.floor(Date.now() / 1000);
    const nonce = newNonce();

    const domain = {
      name: "remit.md",
      version: "0.1",
      chainId: this.#chainId,
      verifyingContract: this.#verifyingContract,
    };

    // Sign the full path (prefix + relative path only, no query string) so it matches
    // the path OriginalUri on the server. The server verifies only the path component.
    // e.g. baseUrl "http://…/api/v1" + path "/events?wallet=0x…" → signed "/api/v1/events"
    const pathOnly = path.split("?")[0];
    const signedPath = `${this.#signPathPrefix}${pathOnly}`;

    // Sign the request metadata (never body — body may be large)
    const signature = await this.#signer.signTypedData(
      domain,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      EIP712_TYPES as any,
      { method, path: signedPath, timestamp: BigInt(timestamp), nonce },
    );

    // Generate idempotency key ONCE on the first attempt, reuse across retries.
    const idemKey = idempotencyKey ?? (
      (method === "POST" || method === "PUT" || method === "PATCH") ? newIdempotencyKey() : undefined
    );

    const headers: Record<string, string> = {
      "Content-Type": "application/json",
      "X-Remit-Agent": this.#signer.getAddress(),
      "X-Remit-Signature": signature,
      "X-Remit-Timestamp": String(timestamp),
      "X-Remit-Nonce": nonce,
    };

    if (idemKey) {
      headers["X-Idempotency-Key"] = idemKey;
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
      return camelizeKeys(await response.json()) as T;
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
      return this.#request<T>(method, path, body, attempt + 1, idemKey);
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
