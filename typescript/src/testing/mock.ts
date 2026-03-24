/**
 * MockRemit — in-memory test double. No network, no chain. <1ms per operation.
 *
 * Usage:
 *   const mock = new MockRemit();
 *   const wallet = mock.createWallet(1000);
 *   const other = mock.createWallet(0);
 *   const tab = await wallet.openTab({ to: other.address, limit: 100, perUnit: 1 });
 */

import { generatePrivateKey, privateKeyToAddress } from "viem/accounts";
import { Wallet } from "../wallet.js";
import {
  InsufficientBalanceError,
  EscrowNotFoundError,
  TabNotFoundError,
  StreamNotFoundError,
  BountyNotFoundError,
} from "../errors.js";
import type {
  Transaction,
  WalletStatus,
  Reputation,
  Webhook,
} from "../models/index.js";
import type { Invoice } from "../models/invoice.js";
import type { Escrow } from "../models/escrow.js";
import type { Tab } from "../models/tab.js";
import type { Stream } from "../models/stream.js";
import type { Bounty } from "../models/bounty.js";
import type { Deposit } from "../models/deposit.js";
let _idCounter = 1;
function nextId(): string {
  return `mock-${_idCounter++}`;
}

function mkTx(invoiceId?: string): Transaction {
  return {
    invoiceId,
    txHash: `0x${nextId()}`,
    chain: "base",
    status: "confirmed",
    createdAt: MockRemit._now(),
  };
}

/** State machine for a mock wallet. */
class MockWalletState {
  balance: number;
  permitNonce: number = 0;
  forcedError: string | null = null;

  constructor(balance: number) {
    this.balance = balance;
  }
}

export class MockRemit {
  readonly #wallets: Map<string, MockWalletState> = new Map();
  readonly #escrows: Map<string, Escrow> = new Map();
  readonly #tabs: Map<string, Tab> = new Map();
  readonly #streams: Map<string, Stream> = new Map();
  readonly #bounties: Map<string, Bounty> = new Map();
  readonly #deposits: Map<string, Deposit> = new Map();
  #timeOffset = 0;

  static _now(): number {
    return Math.floor(Date.now() / 1000);
  }

  _now(): number {
    return MockRemit._now() + this.#timeOffset;
  }

  /** Advance simulated time. Useful for testing timeouts and expirations. */
  advanceTime(seconds: number): void {
    this.#timeOffset += seconds;
  }

  /** Create a mock wallet with a given USDC balance. */
  createWallet(balance = 1000): MockWallet {
    const key = generatePrivateKey();
    const address = privateKeyToAddress(key) as string;
    this.#wallets.set(address, new MockWalletState(balance));
    return new MockWallet(key, this);
  }

  /** Force the next operation for a given wallet address to fail with an error code. */
  setBehavior(address: string, errorCode: string | null): void {
    const state = this.#wallets.get(address);
    if (state) state.forcedError = errorCode;
  }

  _getState(address: string): MockWalletState {
    let state = this.#wallets.get(address);
    if (!state) {
      state = new MockWalletState(0);
      this.#wallets.set(address, state);
    }
    return state;
  }

  _checkForced(address: string): void {
    const state = this._getState(address);
    if (state.forcedError) {
      const code = state.forcedError;
      state.forcedError = null;
      throw new Error(code);
    }
  }

  _debit(address: string, amount: number): void {
    const state = this._getState(address);
    if (state.balance < amount) throw new InsufficientBalanceError();
    state.balance -= amount;
  }

  _credit(address: string, amount: number): void {
    this._getState(address).balance += amount;
  }

  // ─── Read operations ─────────────────────────────────────────────────────────

  getEscrow(id: string): Escrow {
    const e = this.#escrows.get(id);
    if (!e) throw new EscrowNotFoundError();
    return { ...e };
  }

  getTab(id: string): Tab {
    const t = this.#tabs.get(id);
    if (!t) throw new TabNotFoundError();
    return { ...t };
  }

  getStream(id: string): Stream {
    const s = this.#streams.get(id);
    if (!s) throw new StreamNotFoundError();
    return { ...s };
  }

  getBounty(id: string): Bounty {
    const b = this.#bounties.get(id);
    if (!b) throw new BountyNotFoundError();
    return { ...b };
  }

  getDeposit(id: string): Deposit {
    const d = this.#deposits.get(id);
    if (!d) throw new Error("DEPOSIT_NOT_FOUND");
    return { ...d };
  }

  getStatus(address: string): WalletStatus {
    const state = this._getState(address);
    return {
      wallet: address,
      balance: String(state.balance),
      monthlyVolume: "0",
      tier: "trusted",
      feeRateBps: 50,
      activeEscrows: 0,
      activeTabs: 0,
      activeStreams: 0,
      permitNonce: state.permitNonce ?? 0,
    };
  }

  getReputation(address: string): Reputation {
    return {
      address,
      score: 100,
      totalPaid: 0,
      totalReceived: 0,
      escrowsCompleted: 0,
      memberSince: this._now() - 86400 * 30,
    };
  }

  listBounties(status = "open"): Bounty[] {
    return [...this.#bounties.values()].filter((b) => b.status === status);
  }

  // ─── Write operations ────────────────────────────────────────────────────────

  payDirect(from: string, to: string, amount: number): Transaction {
    this._checkForced(from);
    this._debit(from, amount);
    this._credit(to, amount);
    return mkTx();
  }

  fundEscrow(from: string, invoice: Invoice): { tx: Transaction; escrow: Escrow } {
    this._checkForced(from);
    this._debit(from, invoice.amount);
    const id = invoice.id ?? nextId();
    const escrow: Escrow = {
      invoiceId: id,
      txHash: `0x${nextId()}`,
      payer: from,
      payee: invoice.to,
      amount: invoice.amount,
      chain: "base",
      status: "funded",
      createdAt: this._now(),
    };
    this.#escrows.set(id, escrow);
    return { tx: mkTx(id), escrow };
  }

  releaseEscrow(from: string, invoiceId: string): Transaction {
    this._checkForced(from);
    const escrow = this.getEscrow(invoiceId);
    if (escrow.status === "completed") throw new Error("ESCROW_ALREADY_COMPLETED");
    const mut = this.#escrows.get(invoiceId)!;
    mut.status = "completed";
    this._credit(escrow.payee, escrow.amount);
    return mkTx(invoiceId);
  }

  cancelEscrow(from: string, invoiceId: string): Transaction {
    this._checkForced(from);
    const escrow = this.getEscrow(invoiceId);
    const mut = this.#escrows.get(invoiceId)!;
    mut.status = "cancelled";
    this._credit(from, escrow.amount);
    return mkTx(invoiceId);
  }

  openTab(from: string, to: string, limit: number, perUnit: number, expires = 86400): Tab {
    this._checkForced(from);
    this._debit(from, limit);
    const id = nextId();
    const tab: Tab = {
      id,
      payer: from,
      payee: to,
      limit,
      perUnit,
      spent: 0,
      chain: "base",
      status: "open",
      createdAt: this._now(),
      expiresAt: this._now() + expires,
    };
    this.#tabs.set(id, tab);
    return { ...tab };
  }

  closeTab(from: string, tabId: string): Transaction {
    this._checkForced(from);
    const tab = this.getTab(tabId);
    const remaining = tab.limit - tab.spent;
    const mut = this.#tabs.get(tabId)!;
    mut.status = "closed";
    // Refund unspent to payer
    this._credit(from, remaining);
    this._credit(tab.payee, tab.spent);
    return mkTx();
  }

  openStream(from: string, to: string, rate: number, maxDuration = 3600, maxTotal?: number): Stream {
    this._checkForced(from);
    const reserve = maxTotal ?? rate * maxDuration;
    this._debit(from, reserve);
    const id = nextId();
    const stream: Stream = {
      id,
      payer: from,
      payee: to,
      ratePerSecond: rate,
      maxDuration,
      maxTotal,
      totalStreamed: 0,
      chain: "base",
      status: "active",
      startedAt: this._now(),
    };
    this.#streams.set(id, stream);
    return { ...stream };
  }

  closeStream(from: string, streamId: string): Transaction {
    this._checkForced(from);
    const stream = this.getStream(streamId);
    const elapsed = Math.min(this._now() - stream.startedAt, stream.maxDuration);
    const earned = Math.min(elapsed * stream.ratePerSecond, stream.maxTotal ?? Infinity);
    const reserve = stream.maxTotal ?? stream.ratePerSecond * stream.maxDuration;
    const refund = reserve - earned;
    const mut = this.#streams.get(streamId)!;
    mut.status = "closed";
    mut.closedAt = this._now();
    mut.totalStreamed = earned;
    this._credit(stream.payee, earned);
    this._credit(from, refund);
    return mkTx();
  }

  postBounty(
    from: string,
    amount: number,
    task: string,
    deadline: number,
    validation: Bounty["validation"] = "poster",
    maxAttempts = 10,
  ): Bounty {
    this._checkForced(from);
    this._debit(from, amount);
    const id = nextId();
    const bounty: Bounty = {
      id,
      poster: from,
      amount,
      task,
      chain: "base",
      status: "open",
      validation,
      maxAttempts,
      submissions: [],
      createdAt: this._now(),
      deadline,
    };
    this.#bounties.set(id, bounty);
    return { ...bounty };
  }

  submitBounty(from: string, bountyId: string, evidenceHash: string): { id: number } {
    this._checkForced(from);
    const mut = this.#bounties.get(bountyId);
    if (!mut) throw new Error(`bounty ${bountyId} not found`);
    mut.submissions.push({
      submitter: from,
      evidenceUri: evidenceHash,
      submittedAt: this._now(),
    });
    return { id: mut.submissions.length };
  }

  awardBounty(from: string, bountyId: string, submissionId: number): Transaction {
    this._checkForced(from);
    const bounty = this.getBounty(bountyId);
    const mut = this.#bounties.get(bountyId)!;
    const submission = mut.submissions[submissionId - 1];
    if (!submission) throw new Error(`submission ${submissionId} not found`);
    mut.status = "awarded";
    mut.winner = submission.submitter;
    this._credit(submission.submitter, bounty.amount);
    return mkTx();
  }

  placeDeposit(from: string, to: string, amount: number, expires: number): Deposit {
    this._checkForced(from);
    this._debit(from, amount);
    const id = nextId();
    const deposit: Deposit = {
      id,
      payer: from,
      payee: to,
      amount,
      chain: "base",
      status: "locked",
      createdAt: this._now(),
      expiresAt: this._now() + expires,
    };
    this.#deposits.set(id, deposit);
    return { ...deposit };
  }

}

/**
 * MockWallet — a Wallet backed by MockRemit instead of the real API.
 * Overrides all write methods to use the in-memory state machine.
 */
export class MockWallet extends Wallet {
  readonly #mock: MockRemit;

  constructor(privateKey: string, mock: MockRemit) {
    // Pass a dummy apiUrl so no real HTTP is needed
    super({ privateKey, apiUrl: "http://localhost:0" });
    this.#mock = mock;
  }

  override async payDirect(to: string, amount: number, _memo = ""): Promise<Transaction> {
    return this.#mock.payDirect(this.address, to, amount);
  }

  override async pay(invoice: Invoice): Promise<Escrow> {
    const { escrow } = this.#mock.fundEscrow(this.address, invoice);
    return escrow;
  }

  override async releaseEscrow(invoiceId: string): Promise<Transaction> {
    return this.#mock.releaseEscrow(this.address, invoiceId);
  }

  override async cancelEscrow(invoiceId: string): Promise<Transaction> {
    return this.#mock.cancelEscrow(this.address, invoiceId);
  }

  override async openTab(options: Parameters<Wallet["openTab"]>[0]): Promise<Tab> {
    return this.#mock.openTab(
      this.address,
      options.to,
      options.limit,
      options.perUnit,
      options.expires,
    );
  }

  override async closeTab(tabId: string): Promise<Transaction> {
    return this.#mock.closeTab(this.address, tabId);
  }

  override async openStream(options: Parameters<Wallet["openStream"]>[0]): Promise<Stream> {
    return this.#mock.openStream(
      this.address,
      options.to,
      options.rate,
      options.maxDuration,
      options.maxTotal,
    );
  }

  override async closeStream(streamId: string): Promise<Transaction> {
    return this.#mock.closeStream(this.address, streamId);
  }

  override async postBounty(options: Parameters<Wallet["postBounty"]>[0]): Promise<Bounty> {
    return this.#mock.postBounty(
      this.address,
      options.amount,
      options.task,
      options.deadline,
      options.validation,
      options.maxAttempts,
    );
  }

  override async submitBounty(bountyId: string, evidenceHash: string): Promise<Transaction> {
    this.#mock.submitBounty(this.address, bountyId, evidenceHash);
    return mkTx();
  }

  override async awardBounty(bountyId: string, submissionId: number): Promise<Transaction> {
    return this.#mock.awardBounty(this.address, bountyId, submissionId);
  }

  override async placeDeposit(options: Parameters<Wallet["placeDeposit"]>[0]): Promise<Deposit> {
    return this.#mock.placeDeposit(
      this.address,
      options.to,
      options.amount,
      options.expires,
    );
  }

  override async status(): Promise<WalletStatus> {
    return this.#mock.getStatus(this.address);
  }

  override async balance(): Promise<number> {
    return parseFloat((await this.status()).balance);
  }

  override registerWebhook(url: string, events: string[]): Promise<Webhook> {
    const wh: Webhook = {
      id: `wh-${Date.now()}`,
      wallet: this.address,
      url,
      events,
      chains: ["base"],
      active: true,
      createdAt: MockRemit._now(),
    };
    return Promise.resolve(wh);
  }

  override requestTestnetFunds(): Promise<Transaction> {
    this.#mock._credit(this.address, 100);
    return Promise.resolve(mkTx());
  }

  // Override the #auth-based get calls to use mock state
  override getEscrow(invoiceId: string): Promise<import("../models/escrow.js").Escrow> {
    return Promise.resolve(this.#mock.getEscrow(invoiceId));
  }

  override getTab(tabId: string): Promise<Tab> {
    return Promise.resolve(this.#mock.getTab(tabId));
  }

  override getStream(streamId: string): Promise<Stream> {
    return Promise.resolve(this.#mock.getStream(streamId));
  }

  override getBounty(bountyId: string): Promise<Bounty> {
    return Promise.resolve(this.#mock.getBounty(bountyId));
  }

  override getStatus(_wallet: string): Promise<WalletStatus> {
    return this.status();
  }

  override getReputation(wallet: string): Promise<import("../models/index.js").Reputation> {
    return Promise.resolve(this.#mock.getReputation(wallet));
  }
}

