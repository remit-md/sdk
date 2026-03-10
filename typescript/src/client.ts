/**
 * RemitClient — read-only operations, no private key required.
 */

import type { WalletStatus, Reputation, RemitEvent } from "./models/index.js";
import type { Invoice } from "./models/invoice.js";
import type { Escrow } from "./models/escrow.js";
import type { Tab } from "./models/tab.js";
import type { Stream } from "./models/stream.js";
import type { Bounty } from "./models/bounty.js";
import type { Deposit } from "./models/deposit.js";
import type { Dispute } from "./models/dispute.js";
const DEFAULT_API_URLS: Record<string, string> = {
  base: "https://api.remit.md/api/v0",
  "base-sepolia": "https://testnet.remit.md/api/v0",
  arbitrum: "https://api.remit.md/api/v0",
  "arbitrum-sepolia": "https://testnet.remit.md/api/v0",
};

export interface RemitClientOptions {
  chain?: string;
  testnet?: boolean;
  apiUrl?: string;
}

export class RemitClient {
  protected readonly _chain: string;
  protected readonly _apiUrl: string;

  constructor(options: RemitClientOptions = {}) {
    const { chain = "base", testnet = false, apiUrl } = options;
    this._chain = testnet && !chain.includes("sepolia") ? `${chain}-sepolia` : chain;
    this._apiUrl =
      apiUrl ?? DEFAULT_API_URLS[this._chain] ?? DEFAULT_API_URLS["base"];
  }

  protected async _fetch<T>(path: string): Promise<T> {
    const response = await fetch(`${this._apiUrl}${path}`, {
      headers: { "Content-Type": "application/json" },
    });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }
    return (await response.json()) as T;
  }

  getInvoice(invoiceId: string): Promise<Invoice> {
    return this._fetch<Invoice>(`/invoices/${invoiceId}`);
  }

  getEscrow(invoiceId: string): Promise<Escrow> {
    return this._fetch<Escrow>(`/escrows/${invoiceId}`);
  }

  getTab(tabId: string): Promise<Tab> {
    return this._fetch<Tab>(`/tabs/${tabId}`);
  }

  getStream(streamId: string): Promise<Stream> {
    return this._fetch<Stream>(`/streams/${streamId}`);
  }

  getBounty(bountyId: string): Promise<Bounty> {
    return this._fetch<Bounty>(`/bounties/${bountyId}`);
  }

  getDeposit(depositId: string): Promise<Deposit> {
    return this._fetch<Deposit>(`/deposits/${depositId}`);
  }

  getDispute(disputeId: string): Promise<Dispute> {
    return this._fetch<Dispute>(`/disputes/${disputeId}`);
  }

  getStatus(wallet: string): Promise<WalletStatus> {
    return this._fetch<WalletStatus>(`/status/${wallet}`);
  }

  getReputation(wallet: string): Promise<Reputation> {
    return this._fetch<Reputation>(`/reputation/${wallet}`);
  }

  listBounties(options: { status?: string; limit?: number } = {}): Promise<Bounty[]> {
    const params = new URLSearchParams();
    if (options.status) params.set("status", options.status);
    if (options.limit) params.set("limit", String(options.limit));
    const qs = params.toString();
    return this._fetch<Bounty[]>(`/bounties${qs ? `?${qs}` : ""}`);
  }

  getEvents(wallet: string, since?: number): Promise<RemitEvent[]> {
    const qs = since ? `?since=${since}` : "";
    return this._fetch<RemitEvent[]>(`/events/${wallet}${qs}`);
  }
}
