/**
 * Wallet — read + write operations, requires a private key (or custom Signer).
 */

import { randomBytes } from "node:crypto";
import { generatePrivateKey } from "viem/accounts";
import { RemitClient, type RemitClientOptions } from "./client.js";
import { AuthenticatedClient } from "./http.js";
import { PrivateKeySigner, type Signer } from "./signer.js";
import { X402Client, type PaymentRequired } from "./x402.js";
import type {
  Transaction,
  WalletStatus,
  Webhook,
  LinkResponse,
} from "./models/index.js";
import type { Invoice } from "./models/invoice.js";
import type { Escrow } from "./models/escrow.js";
import type { Tab } from "./models/tab.js";
import type { Stream } from "./models/stream.js";
import type { Bounty } from "./models/bounty.js";
import type { Deposit } from "./models/deposit.js";
/** Default public RPC URLs per chain. */
const DEFAULT_RPC_URLS: Record<string, string> = {
  "base-sepolia": "https://sepolia.base.org",
  base: "https://mainnet.base.org",
  localhost: "http://127.0.0.1:8545",
};

export interface WalletOptions extends RemitClientOptions {
  privateKey?: string;
  signer?: Signer;
  /** Router contract address for EIP-712 domain — must match server's ROUTER_ADDRESS. */
  routerAddress?: string;
  /** JSON-RPC URL for on-chain reads (nonce fetching). Falls back to REMITMD_RPC_URL env var, then public defaults. */
  rpcUrl?: string;
}

export interface OpenTabOptions {
  to: string;
  limit: number;
  perUnit: number;
  expires?: number; // seconds
  /** Optional EIP-2612 permit for gasless USDC approval. */
  permit?: PermitSignature;
}

export interface OpenStreamOptions {
  to: string;
  rate: number; // per second
  maxDuration?: number; // seconds
  maxTotal?: number;
  /** Optional EIP-2612 permit for gasless USDC approval. */
  permit?: PermitSignature;
}

/** EIP-2612 permit signature for gasless USDC approval. */
export interface PermitSignature {
  value: number;
  deadline: number;
  v: number;
  r: string;
  s: string;
}

/** Options for signing an EIP-2612 USDC permit. */
export interface SignPermitOptions {
  /** Contract address that will be approved as spender. */
  spender: string;
  /** Amount in USDC base units (6 decimals). */
  value: bigint;
  /** Permit deadline (Unix timestamp). */
  deadline: number;
  /** Current permit nonce for this wallet (default: 0). */
  nonce?: number;
  /** USDC contract address (defaults to Base Sepolia MockUSDC). */
  usdcAddress?: string;
}

export interface PostBountyOptions {
  amount: number;
  task: string;
  deadline: number; // unix timestamp
  validation?: "poster" | "oracle" | "multisig";
  maxAttempts?: number;
  /** Optional EIP-2612 permit for gasless USDC approval. */
  permit?: PermitSignature;
}

export interface PlaceDepositOptions {
  to: string;
  amount: number;
  expires: number; // seconds
  /** Optional EIP-2612 permit for gasless USDC approval. */
  permit?: PermitSignature;
}

export class Wallet extends RemitClient {
  readonly #signer: Signer;
  readonly #auth: AuthenticatedClient;
  readonly #rpcUrl: string;

  constructor(options: WalletOptions = {}) {
    const { privateKey: explicitKey, signer, routerAddress, rpcUrl, ...clientOptions } = options;

    const privateKey =
      explicitKey ?? (!signer ? process.env["REMITMD_KEY"] : undefined);

    if (!privateKey && !signer) {
      throw new Error(
        "Wallet requires privateKey, signer, or the REMITMD_KEY environment variable."
      );
    }

    super(clientOptions);

    this.#rpcUrl = rpcUrl ?? process.env["REMITMD_RPC_URL"] ?? DEFAULT_RPC_URLS[this._chain] ?? DEFAULT_RPC_URLS["base-sepolia"]!;

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

  // ─── EIP-2612 Permit ─────────────────────────────────────────────────────────

  /** Default USDC addresses per chain. */
  static readonly USDC_ADDRESSES: Record<string, string> = {
    "base-sepolia": "0x142aD61B8d2edD6b3807D9266866D97C35Ee0317",
    base: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    localhost: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  };

  /**
   * Sign an EIP-2612 permit for USDC approval.
   * Returns a PermitSignature object that can be passed to postBounty() or placeDeposit().
   */
  async signUsdcPermit(options: SignPermitOptions): Promise<PermitSignature> {
    const usdcAddress = options.usdcAddress ?? Wallet.USDC_ADDRESSES[this._chain] ?? "";

    const domain = {
      name: "USD Coin",
      version: "2",
      chainId: this._chainId,
      verifyingContract: usdcAddress,
    };

    const types = {
      Permit: [
        { name: "owner", type: "address" },
        { name: "spender", type: "address" },
        { name: "value", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    };

    const value = {
      owner: this.address,
      spender: options.spender,
      value: options.value.toString(),
      nonce: options.nonce ?? 0,
      deadline: options.deadline,
    };

    const sig = await this.#signer.signTypedData(domain, types, value);

    // Split signature into v, r, s
    const sigBytes = sig.startsWith("0x") ? sig.slice(2) : sig;
    const r = `0x${sigBytes.slice(0, 64)}`;
    const s = `0x${sigBytes.slice(64, 128)}`;
    const v = parseInt(sigBytes.slice(128, 130), 16);

    return {
      value: Number(options.value),
      deadline: options.deadline,
      v,
      r,
      s,
    };
  }

  /**
   * Convenience: sign an EIP-2612 permit for USDC approval.
   * Auto-fetches the on-chain nonce and sets a default deadline (1 hour).
   * @param spender Contract address that will call transferFrom (e.g. Router, Escrow).
   * @param amount Amount in USDC (e.g. 1.50 for $1.50).
   * @param deadline Optional Unix timestamp. Defaults to 1 hour from now.
   */
  async signPermit(spender: string, amount: number, deadline?: number): Promise<PermitSignature> {
    const usdcAddress = Wallet.USDC_ADDRESSES[this._chain] ?? "";
    const nonce = await this.#fetchUsdcNonce(usdcAddress);
    const dl = deadline ?? Math.floor(Date.now() / 1000) + 3600;
    const rawAmount = BigInt(Math.round(amount * 1e6));
    return this.signUsdcPermit({
      spender,
      value: rawAmount,
      deadline: dl,
      nonce,
      usdcAddress,
    });
  }

  /** Fetch the current EIP-2612 nonce for this wallet from the USDC contract via JSON-RPC. */
  async #fetchUsdcNonce(usdcAddress: string): Promise<number> {
    // nonces(address) selector = 0x7ecebe00 + address padded to 32 bytes
    const paddedAddress = this.address.toLowerCase().replace("0x", "").padStart(64, "0");
    const data = `0x7ecebe00${paddedAddress}`;

    const response = await fetch(this.#rpcUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "eth_call",
        params: [{ to: usdcAddress, data }, "latest"],
      }),
    });

    const json = await response.json() as { result?: string; error?: { message: string } };
    if (json.error) throw new Error(`RPC error fetching nonce: ${json.error.message}`);
    return parseInt(json.result ?? "0x0", 16);
  }

  // ─── Direct Payment ─────────────────────────────────────────────────────────

  payDirect(to: string, amount: number, memo = "", options?: { permit?: PermitSignature }): Promise<Transaction> {
    return this.#auth.post<Transaction>("/payments/direct", {
      to,
      amount,
      task: memo,
      chain: this._chain,
      nonce: randomBytes(16).toString("hex"),
      signature: "0x",
      ...(options?.permit ? { permit: options.permit } : {}),
    });
  }

  // ─── Escrow ─────────────────────────────────────────────────────────────────

  async pay(invoice: Invoice, options?: { permit?: PermitSignature }): Promise<Escrow> {
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
    return this.#auth.post<Escrow>("/escrows", {
      invoice_id: invoiceId,
      ...(options?.permit ? { permit: options.permit } : {}),
    });
  }

  claimStart(invoiceId: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/escrows/${invoiceId}/claim-start`, {});
  }

  submitEvidence(invoiceId: string, evidenceUri: string, milestoneIndex = 0): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/escrows/${invoiceId}/evidence`, {
      evidenceUri,
      milestoneIndex,
    });
  }

  releaseEscrow(invoiceId: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/escrows/${invoiceId}/release`, {});
  }

  releaseMilestone(invoiceId: string, milestoneIndex: number): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/escrows/${invoiceId}/milestones/${milestoneIndex}/release`, {});
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
      ...(options.permit ? { permit: options.permit } : {}),
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
      chain: this._chain,
      to: options.to,
      rate: options.rate,
      maxDuration: options.maxDuration ?? 3600,
      maxTotal: options.maxTotal,
      ...(options.permit ? { permit: options.permit } : {}),
    });
  }

  closeStream(streamId: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/streams/${streamId}/close`);
  }

  // ─── Bounties ───────────────────────────────────────────────────────────────

  postBounty(options: PostBountyOptions): Promise<Bounty> {
    return this.#auth.post<Bounty>("/bounties", {
      chain: this._chain,
      amount: options.amount,
      task: options.task,
      deadline: options.deadline,
      validation: options.validation ?? "poster",
      maxAttempts: options.maxAttempts ?? 10,
      ...(options.permit ? { permit: options.permit } : {}),
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
      ...(options.permit ? { permit: options.permit } : {}),
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

  // ─── Status ─────────────────────────────────────────────────────────────────

  status(): Promise<WalletStatus> {
    return this.#auth.get<WalletStatus>(`/status/${this.address}`);
  }

  async balance(): Promise<number> {
    const s = await this.status();
    return parseFloat(s.balance);
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

  /** @deprecated Use mint() instead. Faucet endpoint returns 410 Gone. */
  requestTestnetFunds(): Promise<Transaction> {
    return this.#auth.post<Transaction>("/faucet", { wallet: this.address });
  }

  /** Mint testnet USDC via POST /mint. Max $2,500 per call, once per hour per wallet. */
  async mint(amount: number): Promise<{ tx_hash: string; balance: number }> {
    const res = await fetch(`${this._apiUrl}/mint`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ wallet: this.address, amount }),
    });
    if (!res.ok) {
      const body = await res.json().catch(() => ({})) as Record<string, unknown>;
      throw new Error(`mint failed (${res.status}): ${(body as Record<string, string>).message ?? res.statusText}`);
    }
    return res.json() as Promise<{ tx_hash: string; balance: number }>;
  }

  // ─── x402 ───────────────────────────────────────────────────────────────────

  /** Make a fetch request, auto-paying any x402 402 responses within maxAutoPayUsdc. */
  async x402Fetch(
    url: string,
    maxAutoPayUsdc = 0.1,
    init?: RequestInit,
  ): Promise<{ response: Response; lastPayment: PaymentRequired | null }> {
    const client = new X402Client({ signer: this.#signer, address: this.address, maxAutoPayUsdc });
    const response = await client.fetch(url, init);
    return { response, lastPayment: client.lastPayment };
  }
}
