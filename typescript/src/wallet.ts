/**
 * Wallet - read + write operations, requires a private key (or custom Signer).
 */

import { randomBytes } from "node:crypto";
import { generatePrivateKey } from "viem/accounts";
import { RemitClient, type RemitClientOptions } from "./client.js";
import { AuthenticatedClient } from "./http.js";
import { PrivateKeySigner, type Signer } from "./signer.js";
import { CliSigner } from "./cli-signer.js";
import { X402Client, type PaymentRequired } from "./x402.js";
import type {
  Transaction,
  WalletStatus,
  Webhook,
  LinkResponse,
  Reputation,
} from "./models/index.js";
import type { Invoice } from "./models/invoice.js";
import type { Escrow } from "./models/escrow.js";
import type { Tab, TabCharge } from "./models/tab.js";
import type { Stream } from "./models/stream.js";
import type { Bounty } from "./models/bounty.js";
import type { Deposit } from "./models/deposit.js";
export interface WalletOptions extends RemitClientOptions {
  privateKey?: string;
  signer?: Signer;
  /** Router contract address for EIP-712 domain - must match server's ROUTER_ADDRESS. */
  routerAddress?: string;
}

export interface OpenTabOptions {
  to: string;
  limit: number;
  perUnit: number;
  expires?: number; // seconds
  /** Pre-signed permit override. Omit to auto-sign (recommended). */
  permit?: PermitSignature;
}

export interface CloseTabOptions {
  /** Final charged amount in USDC. Defaults to 0 (full refund). */
  finalAmount?: number;
  /** Provider's EIP-712 TabCharge signature covering the final state. */
  providerSig?: string;
}

export interface ChargeTabOptions {
  amount: number;
  cumulative: number;
  callCount: number;
  /** Provider's EIP-712 TabCharge signature. */
  providerSig: string;
}

export interface OpenStreamOptions {
  to: string;
  rate: number; // per second
  maxDuration?: number; // seconds
  maxTotal?: number;
  /** Pre-signed permit override. Omit to auto-sign (recommended). */
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

export interface PostBountyOptions {
  amount: number;
  task: string;
  deadline: number; // unix timestamp
  validation?: "poster" | "oracle" | "multisig";
  maxAttempts?: number;
  /** Pre-signed permit override. Omit to auto-sign (recommended). */
  permit?: PermitSignature;
}

export interface PlaceDepositOptions {
  to: string;
  amount: number;
  expires: number; // seconds
  /** Pre-signed permit override. Omit to auto-sign (recommended). */
  permit?: PermitSignature;
}

/**
 * Convert a UUID string to bytes32 matching the server's id_to_bytes32().
 * Encodes the UUID's UTF-8 bytes, left-aligned, zero-padded to 32.
 */
function uuidToBytes32(uuid: string): `0x${string}` {
  const padded = new Uint8Array(32);
  for (let i = 0; i < Math.min(uuid.length, 32); i++) {
    padded[i] = uuid.charCodeAt(i);
  }
  return ("0x" + Array.from(padded, (b) => b.toString(16).padStart(2, "0")).join("")) as `0x${string}`;
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
        "Wallet requires privateKey, signer, or the REMITMD_KEY environment variable. " +
        "For OWS wallet support, use: await Wallet.withOws()"
      );
    }

    super(clientOptions);

    // Router contract address for EIP-712 domain - falls back to env var.
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

  /** Load from environment variables (sync — raw key only).
   *
   * Priority: CliSigner (async) > OWS (async) > REMITMD_KEY > error.
   * For CLI signer or OWS, use the async factories
   * `fromEnvironment()`, `withCli()`, or `withOws()` respectively.
   */
  static fromEnv(overrides?: RemitClientOptions): Wallet {
    const chain = process.env["REMITMD_CHAIN"] ?? "base";

    // Check for CLI signer (async creation needed)
    if (CliSigner.isAvailable()) {
      throw new Error(
        "Remit CLI signer detected - use: await Wallet.withCli() or await Wallet.fromEnvironment()"
      );
    }

    // Check for OWS wallet (async creation needed)
    if (process.env["OWS_WALLET_ID"] && !process.env["REMITMD_KEY"]) {
      throw new Error(
        "OWS_WALLET_ID is set but fromEnv() only supports raw keys. " +
        "Use: await Wallet.withOws()"
      );
    }

    const key = process.env["REMITMD_KEY"];
    if (!key) {
      throw new Error(
        "No signing credentials found. Set one of:\n" +
        "  1. Install Remit CLI + set REMIT_SIGNER_KEY (recommended)\n" +
        "  2. Set OWS_WALLET_ID for OWS wallet\n" +
        "  3. Set REMITMD_KEY for raw private key"
      );
    }
    return new Wallet({ chain, ...overrides, privateKey: key });
  }

  /**
   * Create a Wallet from the environment, trying all signing methods.
   *
   * Priority:
   *   1. CLI signer (remit on PATH + keystore + REMIT_SIGNER_KEY)
   *   2. OWS wallet (OWS_WALLET_ID)
   *   3. Raw private key (REMITMD_KEY)
   *   4. Error with install instructions
   */
  static async fromEnvironment(overrides?: RemitClientOptions): Promise<Wallet> {
    const chain = overrides?.chain ?? process.env["REMITMD_CHAIN"] ?? "base";

    // Priority 1: CLI signer
    if (CliSigner.isAvailable()) {
      try {
        const signer = await CliSigner.create();
        return new Wallet({ chain, ...overrides, signer });
      } catch {
        // CLI detection passed but create failed — fall through
      }
    }

    // Priority 2: OWS wallet
    if (process.env["OWS_WALLET_ID"]) {
      return Wallet.withOws({ chain, ...overrides });
    }

    // Priority 3: Raw private key
    const key = process.env["REMITMD_KEY"];
    if (key) {
      return new Wallet({ chain, ...overrides, privateKey: key });
    }

    // No signing method available
    throw new Error(
      "No signing method available.\n" +
      "  1. Install Remit CLI + set REMIT_SIGNER_KEY (recommended)\n" +
      "     Install: https://remit.md/install\n" +
      "  2. Set OWS_WALLET_ID for OWS wallet\n" +
      "  3. Set REMITMD_KEY for raw private key"
    );
  }

  /**
   * Create a Wallet backed by the Remit CLI signer.
   *
   * The CLI binary must be on PATH (or specify cliPath) and
   * REMIT_SIGNER_KEY must be set. The encrypted keystore at
   * ~/.remit/keys/default.enc is used for signing.
   *
   * @example
   * ```typescript
   * const wallet = await Wallet.withCli();
   * // or with custom CLI path:
   * const wallet = await Wallet.withCli({ cliPath: "/usr/local/bin/remit" });
   * ```
   */
  static async withCli(
    options?: RemitClientOptions & { cliPath?: string },
  ): Promise<Wallet> {
    const signer = await CliSigner.create(options?.cliPath);
    const chain = options?.chain ?? process.env["REMITMD_CHAIN"] ?? "base";
    return new Wallet({ chain, ...options, signer });
  }

  /**
   * Create a Wallet backed by the Open Wallet Standard.
   *
   * Reads OWS_WALLET_ID, OWS_API_KEY, and REMITMD_CHAIN from env unless
   * overridden. Falls back to REMITMD_KEY if OWS_WALLET_ID is not set.
   *
   * @example
   * ```typescript
   * const wallet = await Wallet.withOws();
   * // or with explicit options:
   * const wallet = await Wallet.withOws({ walletId: "remit-my-agent" });
   * ```
   */
  static async withOws(
    options?: RemitClientOptions & {
      walletId?: string;
      owsApiKey?: string;
    },
  ): Promise<Wallet> {
    const owsWalletId = options?.walletId ?? process.env["OWS_WALLET_ID"];
    const remitKey = process.env["REMITMD_KEY"];
    const chain = options?.chain ?? process.env["REMITMD_CHAIN"] ?? "base";

    if (owsWalletId && remitKey) {
      console.warn("[remitmd] Both OWS_WALLET_ID and REMITMD_KEY set. Using OWS.");
    }

    if (owsWalletId) {
      const { OwsSigner } = await import("./ows-signer.js");
      const signer = await OwsSigner.create({
        walletId: owsWalletId,
        chain,
        owsApiKey: options?.owsApiKey ?? process.env["OWS_API_KEY"],
      });
      return new Wallet({ chain, ...options, signer });
    }

    if (remitKey) {
      return new Wallet({ chain, ...options, privateKey: remitKey });
    }

    throw new Error(
      "Wallet.withOws() requires OWS_WALLET_ID or REMITMD_KEY. " +
      "Install OWS: npm install -g @open-wallet-standard/core"
    );
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

  // ─── EIP-2612 Permit (via /permits/prepare) ────────────────────────────────

  /** Contract name → flow name for /permits/prepare. */
  static readonly #CONTRACT_TO_FLOW: Record<string, string> = {
    router: "direct",
    escrow: "escrow",
    tab: "tab",
    stream: "stream",
    bounty: "bounty",
    deposit: "deposit",
    relayer: "direct",
  };

  /**
   * Sign a USDC permit via the server's /permits/prepare endpoint.
   *
   * The server computes the EIP-712 hash, manages nonces, and resolves
   * contract addresses. The SDK only signs the hash.
   *
   * @param flow Payment flow (direct, escrow, tab, stream, bounty, deposit).
   * @param amount Amount in USDC (e.g. 5.0 for $5.00).
   */
  async signPermit(flow: string, amount: number): Promise<PermitSignature> {
    const data = await this.#auth.post<Record<string, string>>("/permits/prepare", {
      flow,
      amount: String(amount),
      owner: this.address,
    });

    const hashHex = data.hash;
    const hashBytes = new Uint8Array(
      (hashHex.startsWith("0x") ? hashHex.slice(2) : hashHex)
        .match(/.{2}/g)!
        .map((b) => parseInt(b, 16)),
    );

    const sig = await this.#signer.signHash(hashBytes);
    const sigHex = sig.startsWith("0x") ? sig.slice(2) : sig;
    const r = `0x${sigHex.slice(0, 64)}`;
    const s = `0x${sigHex.slice(64, 128)}`;
    const v = parseInt(sigHex.slice(128, 130), 16);

    return {
      value: Number(data.value),
      deadline: Number(data.deadline),
      v,
      r,
      s,
    };
  }

  /**
   * Internal: auto-sign a permit via /permits/prepare.
   * Maps the contract name to a flow and calls signPermit().
   * Returns undefined on failure so callers degrade gracefully.
   */
  async #autoPermit(
    contract: "router" | "escrow" | "tab" | "stream" | "bounty" | "deposit" | "relayer",
    amount: number,
  ): Promise<PermitSignature | undefined> {
    const flow = Wallet.#CONTRACT_TO_FLOW[contract];
    if (!flow) {
      console.warn(`[remitmd] unknown contract for permit: ${contract}`);
      return undefined;
    }
    try {
      return await this.signPermit(flow, amount);
    } catch (err) {
      console.warn(`[remitmd] auto-permit failed for ${contract} (amount=${amount}):`, err);
      return undefined;
    }
  }

  // ─── Direct Payment ─────────────────────────────────────────────────────────

  async payDirect(to: string, amount: number, memo = "", options?: { permit?: PermitSignature }): Promise<Transaction> {
    const permit = options?.permit ?? await this.#autoPermit("router", amount);
    return this.#auth.post<Transaction>("/payments/direct", {
      to,
      amount,
      task: memo,
      chain: this._chain,
      nonce: randomBytes(16).toString("hex"),
      signature: "0x",
      ...(permit ? { permit } : {}),
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
    const permit = options?.permit ?? await this.#autoPermit("escrow", invoice.amount);
    return this.#auth.post<Escrow>("/escrows", {
      invoice_id: invoiceId,
      ...(permit ? { permit } : {}),
    });
  }

  claimStart(invoiceId: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/escrows/${invoiceId}/claim-start`, {});
  }

  submitEvidence(invoiceId: string, evidenceUri: string, milestoneIndex = 0): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/escrows/${invoiceId}/claim-start`, {
      evidence_uri: evidenceUri,
      milestone_index: milestoneIndex,
    });
  }

  releaseEscrow(invoiceId: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/escrows/${invoiceId}/release`, {});
  }

  releaseMilestone(invoiceId: string, milestoneIndex: number): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/escrows/${invoiceId}/release`, {
      milestone_ids: [String(milestoneIndex)],
    });
  }

  cancelEscrow(invoiceId: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/escrows/${invoiceId}/cancel`, {});
  }

  // ─── Metered Tabs ───────────────────────────────────────────────────────────

  async openTab(options: OpenTabOptions): Promise<Tab> {
    const permit = options.permit ?? await this.#autoPermit("tab", options.limit);
    return this.#auth.post<Tab>("/tabs", {
      chain: this._chain,
      provider: options.to,
      limit_amount: options.limit,
      per_unit: options.perUnit,
      expiry: Math.floor(Date.now() / 1000) + (options.expires ?? 86400),
      ...(permit ? { permit } : {}),
    });
  }

  /** Sign a TabCharge EIP-712 message (provider-side, for charging or closing a tab). */
  async signTabCharge(
    tabContract: string,
    tabId: string,
    totalCharged: bigint,
    callCount: number,
  ): Promise<string> {
    return this.#signer.signTypedData(
      {
        name: "RemitTab",
        version: "1",
        chainId: this._chainId,
        verifyingContract: tabContract,
      },
      {
        TabCharge: [
          { name: "tabId", type: "bytes32" },
          { name: "totalCharged", type: "uint96" },
          { name: "callCount", type: "uint32" },
        ],
      },
      {
        tabId: uuidToBytes32(tabId),
        totalCharged,
        callCount,
      },
    );
  }

  /** Charge a tab (provider-side). Requires a TabCharge EIP-712 signature. */
  chargeTab(tabId: string, options: ChargeTabOptions): Promise<TabCharge> {
    return this.#auth.post<TabCharge>(`/tabs/${tabId}/charge`, {
      amount: options.amount,
      cumulative: options.cumulative,
      call_count: options.callCount,
      provider_sig: options.providerSig,
    });
  }

  closeTab(tabId: string, options?: CloseTabOptions): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/tabs/${tabId}/close`, {
      final_amount: options?.finalAmount ?? 0,
      provider_sig: options?.providerSig ?? "0x",
    });
  }

  /** Settle and close a tab (alias for closeTab with defaults). */
  settleTab(tabId: string): Promise<Transaction> {
    return this.closeTab(tabId);
  }

  /** @deprecated Use chargeTab instead. */
  debitTab(tabId: string, amount: number, memo = ""): Promise<Record<string, unknown>> {
    return this.#auth.post<Record<string, unknown>>(`/tabs/${tabId}/debit`, {
      tab_id: tabId,
      amount,
      memo,
    });
  }

  // ─── Streaming ──────────────────────────────────────────────────────────────

  async openStream(options: OpenStreamOptions): Promise<Stream> {
    const permit = options.permit ?? (options.maxTotal != null
      ? await this.#autoPermit("stream", options.maxTotal)
      : undefined);
    return this.#auth.post<Stream>("/streams", {
      chain: this._chain,
      payee: options.to,
      rate_per_second: options.rate,
      max_total: options.maxTotal,
      ...(permit ? { permit } : {}),
    });
  }

  closeStream(streamId: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/streams/${streamId}/close`);
  }

  /** Claim all vested stream payments (callable by recipient). */
  withdrawStream(streamId: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/streams/${streamId}/withdraw`);
  }

  // �─── Bounties ───────────────────────────────────────────────────────────────

  async postBounty(options: PostBountyOptions): Promise<Bounty> {
    const permit = options.permit ?? await this.#autoPermit("bounty", options.amount);
    return this.#auth.post<Bounty>("/bounties", {
      chain: this._chain,
      amount: options.amount,
      task_description: options.task,
      deadline: options.deadline,
      max_attempts: options.maxAttempts ?? 10,
      ...(permit ? { permit } : {}),
    });
  }

  submitBounty(bountyId: string, evidenceHash: string, evidenceUri?: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/bounties/${bountyId}/submit`, {
      evidence_hash: evidenceHash,
      ...(evidenceUri ? { evidence_uri: evidenceUri } : {}),
    });
  }

  awardBounty(bountyId: string, submissionId: number): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/bounties/${bountyId}/award`, { submission_id: submissionId });
  }

  // ─── Deposits ───────────────────────────────────────────────────────────────

  async placeDeposit(options: PlaceDepositOptions): Promise<Deposit> {
    const permit = options.permit ?? await this.#autoPermit("deposit", options.amount);
    return this.#auth.post<Deposit>("/deposits", {
      chain: this._chain,
      provider: options.to,
      amount: options.amount,
      expiry: Math.floor(Date.now() / 1000) + options.expires,
      ...(permit ? { permit } : {}),
    });
  }

  returnDeposit(depositId: string): Promise<Transaction> {
    return this.#auth.post<Transaction>(`/deposits/${depositId}/return`, {});
  }

  // ─── Intent Negotiation ──────────────────────────────────────────────────

  /** Propose a payment intent for negotiation (agent-to-agent). */
  proposeIntent(to: string, amount: number, paymentType = "direct"): Promise<Record<string, unknown>> {
    return this.#auth.post<Record<string, unknown>>("/intents", {
      to,
      amount: String(amount),
      type: paymentType,
    });
  }

  /** Alias for proposeIntent. */
  expressIntent(to: string, amount: number, paymentType = "direct"): Promise<Record<string, unknown>> {
    return this.proposeIntent(to, amount, paymentType);
  }

  // ─── Authenticated reads (override unauthenticated base class versions) ──────

  /** GET /escrows/{id} - authenticated; server requires auth to access escrow details. */
  override getEscrow(invoiceId: string): Promise<Escrow> {
    return this.#auth.get<Escrow>(`/escrows/${invoiceId}`);
  }

  /** GET /tabs/{id} - authenticated; server requires auth to access tab details. */
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

  // ─── Analytics ─────────────────────────────────────────────────────────────

  /** Return paginated transaction history. */
  history(page = 1, perPage = 20): Promise<Record<string, unknown>> {
    return this.#auth.get<Record<string, unknown>>(`/wallet/history?page=${page}&per_page=${perPage}`);
  }

  /** Return on-chain reputation for the given address (defaults to self). */
  reputation(address?: string): Promise<Reputation> {
    return this.#auth.get<Reputation>(`/reputation/${address ?? this.address}`);
  }

  /** Return spending analytics for a given period (day/week/month/all). */
  spendingSummary(period = "day"): Promise<Record<string, unknown>> {
    return this.#auth.get<Record<string, unknown>>(`/wallet/spending?period=${period}`);
  }

  /** Return how much the agent can still spend under operator limits. */
  remainingBudget(): Promise<Record<string, unknown>> {
    return this.#auth.get<Record<string, unknown>>("/wallet/budget");
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

  listWebhooks(): Promise<Webhook[]> {
    return this.#auth.get<Webhook[]>("/webhooks");
  }

  deleteWebhook(id: string): Promise<void> {
    return this.#auth.delete<void>(`/webhooks/${id}`);
  }

  // ─── One-time operator links ─────────────────────────────────────────────────

  /** Generate a one-time URL for the operator to fund this wallet.
   *  Auto-signs a permit so the operator can also withdraw from the same link. */
  async createFundLink(options?: {
    messages?: { role: "agent" | "system"; text: string }[];
    agentName?: string;
    permit?: PermitSignature;
  }): Promise<LinkResponse> {
    const permit = options?.permit ?? (await this.#autoPermit("relayer", 999_999_999));
    return this.#auth.post<LinkResponse>("/links/fund", {
      ...(options?.messages && { messages: options.messages }),
      ...(options?.agentName && { agent_name: options.agentName }),
      ...(permit && { permit }),
    });
  }

  /** Generate a one-time URL for the operator to withdraw funds.
   *  Auto-signs an EIP-2612 permit approving the server relayer to transferFrom the agent's wallet. */
  async createWithdrawLink(options?: {
    messages?: { role: "agent" | "system"; text: string }[];
    agentName?: string;
    permit?: PermitSignature;
  }): Promise<LinkResponse> {
    const permit = options?.permit ?? (await this.#autoPermit("relayer", 999_999_999));
    return this.#auth.post<LinkResponse>("/links/withdraw", {
      ...(options?.messages && { messages: options.messages }),
      ...(options?.agentName && { agent_name: options.agentName }),
      ...(permit && { permit }),
    });
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
    const client = new X402Client({
      signer: this.#signer,
      address: this.address,
      maxAutoPayUsdc,
      apiHttp: this.#auth,
    });
    const response = await client.fetch(url, init);
    return { response, lastPayment: client.lastPayment };
  }
}
