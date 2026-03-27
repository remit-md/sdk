/**
 * LocalChain - wraps a local Anvil instance for integration testing.
 * Real EVM, <100ms per operation (requires Anvil in PATH).
 */

import { spawn, type ChildProcess } from "node:child_process";
import { MockWallet, MockRemit } from "./mock.js";

/** Anvil default pre-funded accounts (well-known test keys). */
const ANVIL_KEYS: string[] = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926b",
];

export interface LocalChainOptions {
  port?: number;
  blockTime?: number; // seconds; 0 = instant mining
}

export class LocalChain {
  readonly #port: number;
  readonly #mock: MockRemit;
  #process: ChildProcess | null = null;

  private constructor(port: number) {
    this.#port = port;
    this.#mock = new MockRemit();
  }

  /**
   * Start Anvil, wait for it to be ready, and return a LocalChain instance.
   * Throws if Anvil is not in PATH.
   */
  static async start(options: LocalChainOptions = {}): Promise<LocalChain> {
    const port = options.port ?? 8545;
    const chain = new LocalChain(port);
    await chain.#spawn(options.blockTime ?? 0);
    return chain;
  }

  async #spawn(blockTime: number): Promise<void> {
    const args = ["--port", String(this.#port)];
    if (blockTime > 0) args.push("--block-time", String(blockTime));

    this.#process = spawn("anvil", args, { stdio: "pipe" });

    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("Anvil did not start within 5s")), 5000);

      this.#process!.stdout?.on("data", (data: Buffer) => {
        if (data.toString().includes("Listening on")) {
          clearTimeout(timeout);
          resolve();
        }
      });

      this.#process!.on("error", (err) => {
        clearTimeout(timeout);
        reject(new Error(`Failed to start Anvil: ${err.message}. Is foundry installed?`));
      });
    });
  }

  /** Get a pre-funded wallet by index (0-4). Uses Anvil's default accounts. */
  getWallet(index = 0): MockWallet {
    const key = ANVIL_KEYS[index];
    if (!key) throw new Error(`Wallet index ${index} out of range (0-${ANVIL_KEYS.length - 1})`);
    const wallet = new MockWallet(key, this.#mock);
    this.#mock["_getState"](wallet.address).balance = 10000;
    return wallet;
  }

  /** Advance chain time by `seconds`. */
  async advanceTime(seconds: number): Promise<void> {
    this.#mock.advanceTime(seconds);
    // Also call evm_increaseTime + evm_mine on Anvil
    await this.#rpc("evm_increaseTime", [seconds]);
    await this.#rpc("evm_mine", []);
  }

  /** Mine additional blocks. */
  async mine(blocks = 1): Promise<void> {
    for (let i = 0; i < blocks; i++) {
      await this.#rpc("evm_mine", []);
    }
  }

  /** Save a snapshot. Returns snapshot ID. */
  async snapshot(): Promise<string> {
    const result = await this.#rpc("evm_snapshot", []);
    return result as string;
  }

  /** Revert to a saved snapshot. */
  async revert(snapshotId: string): Promise<void> {
    await this.#rpc("evm_revert", [snapshotId]);
  }

  /** Stop Anvil. */
  stop(): void {
    this.#process?.kill();
    this.#process = null;
  }

  async #rpc(method: string, params: unknown[]): Promise<unknown> {
    const response = await fetch(`http://127.0.0.1:${this.#port}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    });
    const data = (await response.json()) as { result?: unknown; error?: { message: string } };
    if (data.error) throw new Error(`RPC error: ${data.error.message}`);
    return data.result;
  }
}
