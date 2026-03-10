/**
 * Wallet — read + write operations, requires a private key (or custom Signer).
 */

import { generatePrivateKey } from "viem/accounts";
import { RemitClient, type RemitClientOptions } from "./client.js";
import { AuthenticatedClient } from "./http.js";
import { PrivateKeySigner, type Signer } from "./signer.js";
import type {
  Transaction,
  WalletStatus,
  Webhook,
  RemitEvent,
} from "./models/index.js";
import type { Invoice } from "./models/invoice.js";
import type { Tab } from "./models/tab.js";
import type { Stream } from "./models/stream.js";
import type { Bounty } from "./models/bounty.js";
import type { Deposit } from "./models/deposit.js";
import type { Dispute } from "./models/dispute.js";
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

export interface FileDisputeOptions {
  invoiceId: string;
  reason: string;
  details: string;
  evidenceUri: string;
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
    return this.#auth.post<Transaction>("/payments/direct", { to, amount, memo });
  }

  // ─── Escrow ─────────────────────────────────────────────────────────────────

  pay(invoice: Invoice): Promise<Transaction> {
    return this.#auth.post<Transaction>("/invoices", invoice);
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
    return this.#auth.post<Transaction>(`/escrows/${invoiceId}/cancel`);
  }

  // ─── Metered Tabs ───────────────────────────────────────────────────────────

  openTab(options: OpenTabOptions): Promise<Tab> {
    return this.#auth.post<Tab>("/tabs", {
      to: options.to,
      limit: options.limit,
      perUnit: options.perUnit,
      expires: options.expires ?? 86400,
    });
  }

  closeTab(tabId: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/tabs/${tabId}/close`);
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

  // ─── Disputes ───────────────────────────────────────────────────────────────

  fileDispute(options: FileDisputeOptions): Promise<Dispute> {
    return this.#auth.post<Dispute>("/disputes", {
      invoiceId: options.invoiceId,
      reason: options.reason,
      details: options.details,
      evidenceUri: options.evidenceUri,
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

  // ─── Testnet ────────────────────────────────────────────────────────────────

  requestTestnetFunds(): Promise<Transaction> {
    return this.#auth.post<Transaction>("/faucet", { address: this.address });
  }
}
