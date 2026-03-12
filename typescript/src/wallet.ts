/**
 * Wallet — read + write operations, requires a private key (or custom Signer).
 */

import { randomBytes } from "node:crypto";
import { generatePrivateKey } from "viem/accounts";
import { RemitClient, type RemitClientOptions } from "./client.js";
import { AuthenticatedClient } from "./http.js";
import { PrivateKeySigner, type Signer } from "./signer.js";
import { X402Client } from "./x402.js";
import type {
  Transaction,
  WalletStatus,
  Webhook,
  LinkResponse,
  RemitEvent,
} from "./models/index.js";
import type { Invoice } from "./models/invoice.js";
import type { Escrow } from "./models/escrow.js";
import type { Tab } from "./models/tab.js";
import type { Stream } from "./models/stream.js";
import type { Bounty } from "./models/bounty.js";
import type { Deposit } from "./models/deposit.js";
export interface WalletOptions extends RemitClientOptions {
  privateKey?: string;
  signer?: Signer;
  /** Router contract address for EIP-712 domain — must match server's ROUTER_ADDRESS. */
  routerAddress?: string;
}

export interface OpenTabOptions {
  to: string;
  limit: number;
  perUnit: number;
  expires?: number; // seconds
}

export interface OpenStreamOptions {
  to: string;
  rate: number; // per second
  maxDuration?: number; // seconds
  maxTotal?: number;
}

export interface PostBountyOptions {
  amount: number;
  task: string;
  deadline: number; // unix timestamp
  validation?: "poster" | "oracle" | "multisig";
  maxAttempts?: number;
}

export interface PlaceDepositOptions {
  to: string;
  amount: number;
  expires: number; // seconds
}

export class Wallet extends RemitClient {
  readonly #signer: Signer;
  readonly #auth: AuthenticatedClient;

  constructor(options: WalletOptions = {}) {
    const { privateKey: explicitKey, signer, routerAddress, ...clientOptions } = options;

    const privateKey =
      explicitKey ?? (!signer ? process.env["REMITMD_KEY"] : undefined);

    if (!privateKey && !signer) {
      throw new Error(
        "Wallet requires privateKey, signer, or the REMITMD_KEY environment variable."
      );
    }

    super(clientOptions);

    // Router contract address for EIP-712 domain — falls back to env var.
    const verifyingContract =
      routerAddress ?? process.env["REMITMD_ROUTER_ADDRESS"] ?? "";

    this.#signer = signer ?? new PrivateKeySigner(privateKey!);
    this.#auth = new AuthenticatedClient({
      signer: this.#signer,
      baseUrl: this._apiUrl,
      chainId: this._chainId,
      verifyingContract,
    });
  }

  /** Generate a new random wallet (for testing / onboarding). */
  static create(options?: RemitClientOptions): Wallet {
    const key = generatePrivateKey();
    return new Wallet({ ...options, privateKey: key });
  }

  /** Load from REMITMD_KEY and REMITMD_CHAIN environment variables. */
  static fromEnv(overrides?: RemitClientOptions): Wallet {
    const key = process.env["REMITMD_KEY"];
    const chain = process.env["REMITMD_CHAIN"] ?? "base";
    if (!key) throw new Error("REMITMD_KEY environment variable is not set.");
    return new Wallet({ chain, ...overrides, privateKey: key });
  }

  /** Checksummed public address. */
  get address(): string {
    return this.#signer.getAddress();
  }

  /** Prevent private key leakage. */
  toJSON(): Record<string, string> {
    return { address: this.address, chain: this._chain };
  }

  [Symbol.for("nodejs.util.inspect.custom")](): string {
    return `Wallet { address: '${this.address}', chain: '${this._chain}' }`;
  }

  // ─── Direct Payment ─────────────────────────────────────────────────────────

  payDirect(to: string, amount: number, memo = ""): Promise<Transaction> {
    return this.#auth.post<Transaction>("/payments/direct", {
      to,
      amount,
      task: memo,
      chain: this._chain,
      nonce: randomBytes(16).toString("hex"),
      signature: "0x",
    });
  }

  // ─── Escrow ─────────────────────────────────────────────────────────────────

  async pay(invoice: Invoice): Promise<Escrow> {
    // Step 1: create invoice on server.
    const invoiceId = invoice.id || randomBytes(16).toString("hex");
    await this.#auth.post<unknown>("/invoices", {
      id: invoiceId,
      chain: invoice.chain || this._chain,
      from_agent: this.address.toLowerCase(),
      to_agent: invoice.to.toLowerCase(),
      amount: invoice.amount,
      type: invoice.paymentType ?? "escrow",
      task: invoice.memo ?? "",
      nonce: randomBytes(16).toString("hex"),
      signature: "0x",
      ...(invoice.timeout ? { escrow_timeout: invoice.timeout } : {}),
    });
    // Step 2: fund the escrow and return it.
    return this.#auth.post<Escrow>("/escrows", { invoice_id: invoiceId });
  }

  claimStart(invoiceId: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/escrows/${invoiceId}/claim-start`);
  }

  submitEvidence(invoiceId: string, evidenceUri: string, milestoneIndex = 0): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/escrows/${invoiceId}/evidence`, {
      evidenceUri,
      milestoneIndex,
    });
  }

  releaseEscrow(invoiceId: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/escrows/${invoiceId}/release`);
  }

  releaseMilestone(invoiceId: string, milestoneIndex: number): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/escrows/${invoiceId}/milestones/${milestoneIndex}/release`);
  }

  cancelEscrow(invoiceId: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/escrows/${invoiceId}/cancel`, {});
  }

  // ─── Metered Tabs ───────────────────────────────────────────────────────────

  openTab(options: OpenTabOptions): Promise<Tab> {
    return this.#auth.post<Tab>("/tabs", {
      chain: this._chain,
      provider: options.to,
      limit_amount: options.limit,
      per_unit: options.perUnit,
      expiry: Math.floor(Date.now() / 1000) + (options.expires ?? 86400),
    });
  }

  closeTab(tabId: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/tabs/${tabId}/close`, {
      final_amount: 0,
      provider_sig: "0x",
    });
  }

  // ─── Streaming ──────────────────────────────────────────────────────────────

  openStream(options: OpenStreamOptions): Promise<Stream> {
    return this.#auth.post<Stream>("/streams", {
      to: options.to,
      rate: options.rate,
      maxDuration: options.maxDuration ?? 3600,
      maxTotal: options.maxTotal,
    });
  }

  closeStream(streamId: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/streams/${streamId}/close`);
  }

  // ─── Bounties ───────────────────────────────────────────────────────────────

  postBounty(options: PostBountyOptions): Promise<Bounty> {
    return this.#auth.post<Bounty>("/bounties", {
      amount: options.amount,
      task: options.task,
      deadline: options.deadline,
      validation: options.validation ?? "poster",
      maxAttempts: options.maxAttempts ?? 10,
    });
  }

  submitBounty(bountyId: string, evidenceUri: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/bounties/${bountyId}/submit`, { evidenceUri });
  }

  awardBounty(bountyId: string, winner: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/bounties/${bountyId}/award`, { winner });
  }

  // ─── Deposits ───────────────────────────────────────────────────────────────

  placeDeposit(options: PlaceDepositOptions): Promise<Deposit> {
    return this.#auth.post<Deposit>("/deposits", {
      to: options.to,
      amount: options.amount,
      expires: options.expires,
    });
  }

  // ─── Authenticated reads (override unauthenticated base class versions) ──────

  /** GET /escrows/{id} — authenticated; server requires auth to access escrow details. */
  override getEscrow(invoiceId: string): Promise<Escrow> {
    return this.#auth.get<Escrow>(`/escrows/${invoiceId}`);
  }

  /** GET /tabs/{id} — authenticated; server requires auth to access tab details. */
  override getTab(tabId: string): Promise<Tab> {
    return this.#auth.get<Tab>(`/tabs/${tabId}`);
  }

  /** GET /events?wallet={wallet} — authenticated. Server uses wallet as query param. */
  override getEvents(wallet: string, since?: number): Promise<RemitEvent[]> {
    let qs = `?wallet=${encodeURIComponent(wallet)}`;
    if (since !== undefined) qs += `&since=${since}`;
    return this.#auth.get<RemitEvent[]>(`/events${qs}`)
      .then((data) => {
        // Server may return { items: [...] } or [...] directly
        if (Array.isArray(data)) return data;
        const obj = data as { items?: RemitEvent[] };
        return obj.items ?? [];
      });
  }

  // ─── Events ─────────────────────────────────────────────────────────────────

  /** Register a callback for a named event type. Uses polling when no webhook is active. */
  on(event: string, callback: (data: RemitEvent) => void): void {
    // Polling fallback: check events every 5s
    const poll = async (): Promise<void> => {
      try {
        const events = await this.getEvents(this.address);
        for (const ev of events) {
          if (ev.type === event || event === "*") {
            callback(ev);
          }
        }
      } catch {
        // Swallow poll errors; retry on next interval
      }
      setTimeout(() => void poll(), 5000);
    };
    void poll();
  }

  // ─── Status ─────────────────────────────────────────────────────────────────

  status(): Promise<WalletStatus> {
    return this.#auth.get<WalletStatus>(`/status/${this.address}`);
  }

  async balance(): Promise<number> {
    const s = await this.status();
    return s.usdcBalance;
  }

  // ─── Webhooks ───────────────────────────────────────────────────────────────

  registerWebhook(
    url: string,
    events: string[],
    chains?: string[],
  ): Promise<Webhook> {
    return this.#auth.post<Webhook>("/webhooks", {
      url,
      events,
      chains: chains ?? [this._chain],
    });
  }

  // ─── One-time operator links ─────────────────────────────────────────────────

  /** Generate a one-time URL for the operator to fund this wallet. */
  createFundLink(): Promise<LinkResponse> {
    return this.#auth.post<LinkResponse>("/links/fund", {});
  }

  /** Generate a one-time URL for the operator to withdraw funds. */
  createWithdrawLink(): Promise<LinkResponse> {
    return this.#auth.post<LinkResponse>("/links/withdraw", {});
  }

  // ─── Testnet ────────────────────────────────────────────────────────────────

  requestTestnetFunds(): Promise<Transaction> {
    return this.#auth.post<Transaction>("/faucet", { wallet: this.address });
  }

  // ─── x402 ───────────────────────────────────────────────────────────────────

  /** Make a fetch request, auto-paying any x402 402 responses within maxAutoPayUsdc. */
  x402Fetch(url: string, maxAutoPayUsdc = 0.1, init?: RequestInit): Promise<Response> {
    const client = new X402Client({ signer: this.#signer, address: this.address, maxAutoPayUsdc });
    return client.fetch(url, init);
  }
}
