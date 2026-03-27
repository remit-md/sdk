/**
 * CLI signer adapter for the remit CLI binary.
 *
 * Delegates EIP-712 signing to the `remit sign` subprocess. The CLI
 * holds the encrypted keystore; this adapter only needs the binary on
 * PATH and the REMIT_KEY_PASSWORD env var set.
 *
 * Usage:
 *   const signer = await CliSigner.create();
 *   const wallet = new Wallet({ signer });
 */

import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import type { Signer, TypedDataDomain, TypedDataTypes } from "./signer.js";

const execFileAsync = promisify(execFile);

/** Run a CLI command with stdin input and return stdout/stderr. */
function spawnWithStdin(
  cmd: string,
  args: string[],
  input: string,
  timeout: number,
): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ["pipe", "pipe", "pipe"], timeout });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => { stdout += chunk.toString(); });
    child.stderr.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(stderr.trim() || `process exited with code ${code}`));
      } else {
        resolve({ stdout, stderr });
      }
    });
    child.stdin.write(input);
    child.stdin.end();
  });
}

/** Default timeout for CLI subprocess calls (ms). */
const CLI_TIMEOUT = 10_000;

/**
 * Signer backed by the `remit sign` CLI command.
 *
 * - No key material in this process — signing happens in a subprocess.
 * - Address is cached at construction time via `remit address`.
 * - signTypedData() pipes EIP-712 JSON to `remit sign --eip712` on stdin.
 * - All errors are explicit — no silent fallbacks.
 */
export class CliSigner implements Signer {
  readonly #cliPath: string;
  #address: string | null = null;

  private constructor(cliPath: string) {
    this.#cliPath = cliPath;
  }

  /**
   * Create a CliSigner, fetching and caching the wallet address.
   *
   * @throws If the CLI is not found, keystore is missing, or address is invalid.
   */
  static async create(cliPath: string = "remit"): Promise<CliSigner> {
    const signer = new CliSigner(cliPath);
    const { stdout } = await execFileAsync(cliPath, ["address"], {
      timeout: CLI_TIMEOUT,
    });
    signer.#address = stdout.trim();
    if (!signer.#address.startsWith("0x") || signer.#address.length !== 42) {
      throw new Error(`CliSigner: invalid address from CLI: ${signer.#address}`);
    }
    return signer;
  }

  getAddress(): string {
    if (!this.#address) {
      throw new Error("CliSigner not initialized. Use CliSigner.create()");
    }
    return this.#address;
  }

  async signTypedData(
    domain: TypedDataDomain,
    types: TypedDataTypes,
    value: Record<string, unknown>,
  ): Promise<string> {
    const input = JSON.stringify(
      { domain, types, message: value },
      (_key, v) =>
        typeof v === "bigint"
          ? v <= Number.MAX_SAFE_INTEGER
            ? Number(v)
            : v.toString()
          : (v as unknown),
    );

    let result: { stdout: string; stderr: string };
    try {
      result = await spawnWithStdin(
        this.#cliPath,
        ["sign", "--eip712"],
        input,
        CLI_TIMEOUT,
      );
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      throw new Error(`CliSigner: signing failed: ${msg}`);
    }

    const sig = result.stdout.trim();
    if (!sig.startsWith("0x") || sig.length !== 132) {
      throw new Error(
        `CliSigner: invalid signature from CLI: ${result.stderr.trim() || sig}`,
      );
    }
    return sig;
  }

  /**
   * Check all three conditions for CliSigner activation:
   * 1. Keystore file exists at ~/.remit/keys/default.enc
   * 2. REMIT_KEY_PASSWORD env var is set
   *
   * Note: CLI presence on PATH is not checked synchronously — it's
   * verified when create() is called.
   */
  static isAvailable(): boolean {
    try {
      const keystorePath = join(homedir(), ".remit", "keys", "default.enc");
      if (!existsSync(keystorePath)) return false;
      if (!process.env["REMIT_KEY_PASSWORD"]) return false;
      return true;
    } catch {
      return false;
    }
  }

  /** Prevent credential leakage in serialization. */
  toJSON(): Record<string, string> {
    return { address: this.#address ?? "uninitialized" };
  }

  [Symbol.for("nodejs.util.inspect.custom")](): string {
    return `CliSigner { address: '${this.#address ?? "uninitialized"}' }`;
  }
}
