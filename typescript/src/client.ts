/**
 * RemitClient — read-only operations, no private key required.
 */

import type { WalletStatus, Reputation, ContractAddresses } from "./models/index.js";
import type { Invoice } from "./models/invoice.js";
import type { Escrow } from "./models/escrow.js";
import type { Tab } from "./models/tab.js";
import type { Stream } from "./models/stream.js";
import type { Bounty } from "./models/bounty.js";
import type { Deposit } from "./models/deposit.js";
const DEFAULT_API_URLS: Record<string, string> = {
  base: "https://remit.md/api/v1",
  "base-sepolia": "https://testnet.remit.md/api/v1",
  localhost: "http://localhost:3000/api/v1",
};

export const CHAIN_IDS: Record<string, number> = {
  base: 8453,
  "base-sepolia": 84532,
  localhost: 31337,
};

export interface RemitClientOptions {
  chain?: string;
  testnet?: boolean;
  apiUrl?: string;
}

export class RemitClient {
  protected readonly _chain: string;
  protected readonly _apiUrl: string;
  protected readonly _chainId: number;
  #contractsCache: ContractAddresses | null = null;

  constructor(options: RemitClientOptions = {}) {
    const { chain = "base", testnet = false, apiUrl } = options;
    this._chain = testnet && !chain.includes("sepolia") ? `${chain}-sepolia` : chain;
    const envUrl = typeof process !== "undefined" ? process.env.REMITMD_API_URL : undefined;
    const resolvedUrl = apiUrl ?? envUrl ?? DEFAULT_API_URLS[this._chain];
    if (!resolvedUrl) {
      throw new Error(
        `Unknown chain '${this._chain}'. Supported chains: ${Object.keys(DEFAULT_API_URLS).join(", ")}. ` +
        "Pass apiUrl explicitly or set REMITMD_API_URL.",
      );
    }
    this._apiUrl = resolvedUrl;
    const resolvedChainId = CHAIN_IDS[this._chain];
    if (resolvedChainId === undefined) {
      throw new Error(
        `Unknown chain '${this._chain}'. Supported chains: ${Object.keys(CHAIN_IDS).join(", ")}.`,
      );
    }
    this._chainId = resolvedChainId;
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

  getStatus(wallet: string): Promise<WalletStatus> {
    return this._fetch<WalletStatus>(`/status/${wallet}`);
  }

  getReputation(wallet: string): Promise<Reputation> {
    return this._fetch<Reputation>(`/reputation/${wallet}`);
  }

  /** Get deployed contract addresses. Cached for the lifetime of this client instance. */
  async getContracts(): Promise<ContractAddresses> {
    if (this.#contractsCache) return this.#contractsCache;
    const contracts = await this._fetch<ContractAddresses>("/contracts");
    this.#contractsCache = contracts;
    return contracts;
  }

  listBounties(options: { status?: string; limit?: number; poster?: string; submitter?: string } = {}): Promise<Bounty[]> {
    const params = new URLSearchParams();
    if (options.status) params.set("status", options.status);
    if (options.limit) params.set("limit", String(options.limit));
    if (options.poster) params.set("poster", options.poster);
    if (options.submitter) params.set("submitter", options.submitter);
    const qs = params.toString();
    return this._fetch<Bounty[]>(`/bounties${qs ? `?${qs}` : ""}`);
  }

}
