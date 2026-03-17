/**
 * x402 service provider middleware for gating HTTP endpoints behind payments.
 *
 * Providers use this module to:
 * - Return HTTP 402 responses with properly formatted `PAYMENT-REQUIRED` headers
 * - Verify incoming `PAYMENT-SIGNATURE` headers against the remit.md facilitator
 *
 * Usage (Hono / Cloudflare Workers / any fetch-based framework):
 * ```typescript
 * import { X402Paywall } from "@remitmd/sdk/provider";
 *
 * const paywall = new X402Paywall({
 *   walletAddress: "0xYourProviderWallet",
 *   routerAddress: "0x887536bD817B758f99F090a80F48032a24f50916",
 *   amountUsdc: 0.001,
 *   network: "eip155:84532",
 *   asset: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
 *   facilitatorToken: "your-bearer-jwt",
 *   resource: "/v1/data",
 *   description: "Realtime market data feed",
 *   mimeType: "application/json",
 * });
 *
 * // Returns a 402 Response if payment is absent/invalid, null if payment ok.
 * const block = await paywall.handle(request);
 * if (block) return block;
 * return new Response("here is your data");
 * ```
 *
 * Usage (Hono):
 * ```typescript
 * app.use("/v1/*", paywall.honoMiddleware());
 * ```
 *
 * Usage (Express-style):
 * ```typescript
 * app.get("/v1/data", paywall.expressMiddleware(), (req, res) => {
 *   res.json({ data: "..." });
 * });
 * ```
 */

/** Configuration for {@link X402Paywall}. */
export interface PaywallOptions {
  /** Provider's checksummed Ethereum address. */
  walletAddress: string;
  /** RemitRouter contract address. The agent signs the EIP-3009 authorization to this address.
   *  The Router deducts the protocol fee and forwards the net amount to `walletAddress`.
   *  Required for fee-enforced x402 payments. */
  routerAddress: string;
  /** Price per request in USDC (e.g. `0.001`). */
  amountUsdc: number;
  /** CAIP-2 network string (e.g. `"eip155:84532"` for Base Sepolia). */
  network: string;
  /** USDC contract address on the target network. */
  asset: string;
  /** Base URL of the remit.md facilitator (default: `"https://remit.md"`). */
  facilitatorUrl?: string;
  /** Bearer JWT for authenticating calls to `/api/v0/x402/verify`. */
  facilitatorToken?: string;
  /** How long the payment authorization remains valid in seconds (default: 60). */
  maxTimeoutSeconds?: number;
  /** V2 — URL or path of the resource being protected (e.g. `"/v1/data"`). */
  resource?: string;
  /** V2 — Human-readable description of what the payment is for. */
  description?: string;
  /** V2 — MIME type of the resource (e.g. `"application/json"`). */
  mimeType?: string;
}

/** Result of {@link X402Paywall.check}. */
export interface CheckResult {
  isValid: boolean;
  /** Populated when `isValid` is false and the signature was present. */
  invalidReason?: string;
}

/** x402 paywall for service providers. */
export class X402Paywall {
  readonly #walletAddress: string;
  readonly #routerAddress: string;
  readonly #amountBaseUnits: string;
  readonly #network: string;
  readonly #asset: string;
  readonly #facilitatorUrl: string;
  readonly #facilitatorToken: string;
  readonly #maxTimeoutSeconds: number;
  readonly #resource: string | undefined;
  readonly #description: string | undefined;
  readonly #mimeType: string | undefined;

  constructor({
    walletAddress,
    routerAddress,
    amountUsdc,
    network,
    asset,
    facilitatorUrl = "https://remit.md",
    facilitatorToken = "",
    maxTimeoutSeconds = 60,
    resource,
    description,
    mimeType,
  }: PaywallOptions) {
    this.#walletAddress = walletAddress;
    this.#routerAddress = routerAddress;
    this.#amountBaseUnits = String(Math.round(amountUsdc * 1_000_000));
    this.#network = network;
    this.#asset = asset;
    this.#facilitatorUrl = facilitatorUrl.replace(/\/$/, "");
    this.#facilitatorToken = facilitatorToken;
    this.#maxTimeoutSeconds = maxTimeoutSeconds;
    this.#resource = resource;
    this.#description = description;
    this.#mimeType = mimeType;
  }

  /** Return the base64-encoded JSON `PAYMENT-REQUIRED` header value. */
  paymentRequiredHeader(): string {
    const payload: Record<string, unknown> = {
      scheme: "exact",
      network: this.#network,
      amount: this.#amountBaseUnits,
      asset: this.#asset,
      payTo: this.#routerAddress,
      recipient: this.#walletAddress,
      maxTimeoutSeconds: this.#maxTimeoutSeconds,
    };
    if (this.#resource !== undefined) payload["resource"] = this.#resource;
    if (this.#description !== undefined) payload["description"] = this.#description;
    if (this.#mimeType !== undefined) payload["mimeType"] = this.#mimeType;
    return Buffer.from(JSON.stringify(payload)).toString("base64");
  }

  #paymentRequiredObject() {
    return {
      scheme: "exact",
      network: this.#network,
      amount: this.#amountBaseUnits,
      asset: this.#asset,
      payTo: this.#routerAddress,
      recipient: this.#walletAddress,
      maxTimeoutSeconds: this.#maxTimeoutSeconds,
    };
  }

  /**
   * Check whether a `PAYMENT-SIGNATURE` header represents a valid payment.
   *
   * Calls the remit.md facilitator's `/api/v0/x402/verify` endpoint.
   *
   * @param paymentSig The raw header value (base64 JSON), or null if absent.
   * @returns `{ isValid: true }` or `{ isValid: false, invalidReason }`.
   */
  async check(paymentSig: string | null): Promise<CheckResult> {
    if (!paymentSig) {
      return { isValid: false };
    }

    let paymentPayload: unknown;
    try {
      paymentPayload = JSON.parse(Buffer.from(paymentSig, "base64").toString("utf8"));
    } catch {
      return { isValid: false, invalidReason: "INVALID_PAYLOAD" };
    }

    const body = {
      paymentPayload,
      paymentRequired: this.#paymentRequiredObject(),
    };

    const headers: Record<string, string> = {
      "Content-Type": "application/json",
    };
    if (this.#facilitatorToken) {
      headers["Authorization"] = `Bearer ${this.#facilitatorToken}`;
    }

    let data: { isValid?: boolean; invalidReason?: string };
    try {
      const resp = await globalThis.fetch(`${this.#facilitatorUrl}/api/v0/x402/verify`, {
        method: "POST",
        headers,
        body: JSON.stringify(body),
      });
      if (!resp.ok) {
        return { isValid: false, invalidReason: "FACILITATOR_ERROR" };
      }
      data = (await resp.json()) as { isValid?: boolean; invalidReason?: string };
    } catch {
      return { isValid: false, invalidReason: "FACILITATOR_ERROR" };
    }

    return {
      isValid: data.isValid === true,
      invalidReason: data.invalidReason,
    };
  }

  /**
   * Web-standard (fetch API) middleware compatible with Hono, Cloudflare Workers, etc.
   *
   * Returns a 402 `Response` if payment is absent or invalid, or `null` to allow
   * the request to proceed.
   *
   * @param request Incoming `Request` object.
   */
  async handle(request: Request): Promise<Response | null> {
    const paymentSig = request.headers.get("payment-signature");
    const result = await this.check(paymentSig);
    if (!result.isValid) {
      return new Response(JSON.stringify({ error: "Payment required", invalidReason: result.invalidReason }), {
        status: 402,
        headers: {
          "Content-Type": "application/json",
          "PAYMENT-REQUIRED": this.paymentRequiredHeader(),
        },
      });
    }
    return null;
  }

  /**
   * Express-style middleware factory.
   *
   * @example
   * ```typescript
   * app.get("/v1/data", paywall.expressMiddleware(), (req, res) => {
   *   res.json({ data: "..." });
   * });
   * ```
   */
  expressMiddleware(): (
    req: { headers: Record<string, string | string[] | undefined> },
    res: {
      status(code: number): { set(headers: Record<string, string>): { json(body: unknown): void } };
    },
    next: () => void,
  ) => Promise<void> {
    return async (req, res, next) => {
      const raw = req.headers["payment-signature"];
      const paymentSig = Array.isArray(raw) ? raw[0] ?? null : (raw ?? null);
      const result = await this.check(paymentSig);
      if (!result.isValid) {
        res
          .status(402)
          .set({ "PAYMENT-REQUIRED": this.paymentRequiredHeader(), "Content-Type": "application/json" })
          .json({ error: "Payment required", invalidReason: result.invalidReason });
        return;
      }
      next();
    };
  }

  /**
   * Hono middleware factory.
   *
   * Compatible with Hono v3/v4 and any framework that uses the same
   * `(c, next) => Promise<void>` middleware signature.
   *
   * @example
   * ```typescript
   * import { Hono } from "hono";
   * app.use("/v1/*", paywall.honoMiddleware());
   * ```
   */
  honoMiddleware(): (
    c: {
      req: { raw: Request };
      header(name: string, value: string): void;
      body(content: string, status?: number): Response;
    },
    next: () => Promise<void>,
  ) => Promise<Response | void> {
    return async (c, next) => {
      const paymentSig = c.req.raw.headers.get("payment-signature");
      const result = await this.check(paymentSig);
      if (!result.isValid) {
        c.header("PAYMENT-REQUIRED", this.paymentRequiredHeader());
        c.header("Content-Type", "application/json");
        return c.body(JSON.stringify({ error: "Payment required", invalidReason: result.invalidReason }), 402);
      }
      await next();
    };
  }

  /** Prevent sensitive config leakage. */
  toJSON(): Record<string, string> {
    return { walletAddress: this.#walletAddress, network: this.#network };
  }
}
