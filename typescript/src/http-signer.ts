/**
 * HTTP signer adapter for the remit local signer server.
 *
 * Delegates EIP-712 signing to an HTTP server on localhost (typically
 * `http://127.0.0.1:7402`). The signer server holds the encrypted key;
 * this adapter only needs a bearer token and URL.
 *
 * Usage:
 *   const signer = await HttpSigner.create({ url: "http://127.0.0.1:7402", token: "rmit_sk_..." });
 *   const wallet = new Wallet({ signer });
 */

import type { Signer, TypedDataDomain, TypedDataTypes } from "./signer.js";

/** Options for {@link HttpSigner.create}. */
export interface HttpSignerOptions {
  /** Signer server URL (e.g., "http://127.0.0.1:7402"). */
  url: string;
  /** Bearer token for authentication. */
  token: string;
}

/** Response from GET /address. */
interface AddressResponse {
  address: string;
}

/** Response from POST /sign/typed-data. */
interface SignatureResponse {
  signature: string;
}

/** Error response from the signer server. */
interface SignerErrorResponse {
  error: string;
  reason?: string;
}

/**
 * Signer backed by a local HTTP signing server.
 *
 * - Bearer token is held in a private field, never serialized.
 * - Address is cached at construction time (GET /address).
 * - signTypedData() POSTs structured EIP-712 data to /sign/typed-data.
 * - All errors are explicit - no silent fallbacks, no default values.
 */
export class HttpSigner implements Signer {
  readonly #url: string;
  readonly #token: string;
  #address: string | null = null;

  private constructor(options: HttpSignerOptions) {
    this.#url = options.url.replace(/\/+$/, "");
    this.#token = options.token;
  }

  /**
   * Create an HttpSigner, fetching and caching the wallet address.
   *
   * @throws If the signer server is unreachable or returns an error.
   */
  static async create(options: HttpSignerOptions): Promise<HttpSigner> {
    const signer = new HttpSigner(options);

    const res = await fetch(`${signer.#url}/address`, {
      headers: { Authorization: `Bearer ${options.token}` },
    }).catch((e: Error) => {
      throw new Error(`HttpSigner: cannot reach signer server at ${options.url}: ${e.message}`);
    });

    if (!res.ok) {
      const body = await res.json().catch(() => ({}) as SignerErrorResponse);
      throw new Error(
        `HttpSigner: GET /address failed (${res.status}): ${(body as SignerErrorResponse).reason ?? (body as SignerErrorResponse).error ?? res.statusText}`,
      );
    }

    const data = (await res.json()) as AddressResponse;
    if (!data.address) {
      throw new Error("HttpSigner: GET /address returned no address");
    }
    signer.#address = data.address;
    return signer;
  }

  getAddress(): string {
    if (!this.#address) {
      throw new Error("HttpSigner not initialized. Use HttpSigner.create()");
    }
    return this.#address;
  }

  async signTypedData(
    domain: TypedDataDomain,
    types: TypedDataTypes,
    value: Record<string, unknown>,
  ): Promise<string> {
    const res = await fetch(`${this.#url}/sign/typed-data`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.#token}`,
      },
      body: JSON.stringify({ domain, types, value }, (_key, v) =>
        typeof v === "bigint" ? v.toString() : (v as unknown),
      ),
    }).catch((e: Error) => {
      throw new Error(`HttpSigner: cannot reach signer server: ${e.message}`);
    });

    if (res.status === 401) {
      throw new Error("HttpSigner: unauthorized - check your REMIT_SIGNER_TOKEN");
    }

    if (res.status === 403) {
      const body = (await res.json().catch(() => ({}))) as SignerErrorResponse;
      throw new Error(
        `HttpSigner: policy denied - ${body.reason ?? "unknown reason"}`,
      );
    }

    if (!res.ok) {
      const body = (await res.json().catch(() => ({}))) as SignerErrorResponse;
      throw new Error(
        `HttpSigner: sign failed (${res.status}): ${body.reason ?? body.error ?? res.statusText}`,
      );
    }

    const data = (await res.json()) as SignatureResponse;
    if (!data.signature) {
      throw new Error("HttpSigner: server returned no signature");
    }
    return data.signature;
  }

  /** Prevent token leakage in serialization. */
  toJSON(): Record<string, string> {
    return { address: this.#address ?? "uninitialized" };
  }

  [Symbol.for("nodejs.util.inspect.custom")](): string {
    return `HttpSigner { address: '${this.#address ?? "uninitialized"}' }`;
  }
}
