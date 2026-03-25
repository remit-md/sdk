/**
 * OWS (Open Wallet Standard) signer adapter.
 *
 * Wraps the @open-wallet-standard/core FFI module to implement the Remit
 * Signer interface. OWS handles encrypted key storage + policy-gated signing;
 * this adapter translates between Remit's (domain, types, value) EIP-712
 * calling convention and OWS's JSON string convention.
 *
 * Usage:
 *   const signer = await OwsSigner.create({ walletId: "remit-my-agent" });
 *   const wallet = new Wallet({ signer });
 */

import type { Signer, TypedDataDomain, TypedDataTypes } from "./signer.js";

/** Subset of @open-wallet-standard/core we call at runtime. */
interface OwsModule {
  getWallet(nameOrId: string, vaultPath?: string): {
    id: string;
    name: string;
    accounts: Array<{ chainId: string; address: string; derivationPath: string }>;
    createdAt: string;
  };
  signTypedData(
    wallet: string,
    chain: string,
    typedDataJson: string,
    passphrase?: string,
    index?: number,
    vaultPath?: string,
  ): { signature: string; recoveryId?: number };
}

/** Options for {@link OwsSigner.create}. */
export interface OwsSignerOptions {
  /** OWS wallet name or UUID (e.g. "remit-my-agent"). */
  walletId: string;
  /** Remit chain name — only used for logging, not passed to OWS. Default: "base". */
  chain?: string;
  /** OWS API key token (passed as passphrase to OWS signing calls). */
  owsApiKey?: string;
  /** @internal Inject OWS module for testing — bypasses dynamic import. */
  _owsModule?: unknown;
}

/**
 * Signer backed by the Open Wallet Standard.
 *
 * - Keys live in OWS's encrypted vault (~/.ows/wallets/), never in env vars.
 * - Signing calls go through OWS FFI, which evaluates policy rules before signing.
 * - Use the static {@link create} factory — the constructor is private because
 *   address resolution requires a synchronous FFI call that must happen before
 *   getAddress() can work.
 */
export class OwsSigner implements Signer {
  readonly #walletId: string;
  readonly #address: string;
  readonly #owsApiKey: string | undefined;
  readonly #ows: OwsModule;

  private constructor(
    walletId: string,
    address: string,
    owsModule: OwsModule,
    owsApiKey?: string,
  ) {
    this.#walletId = walletId;
    this.#address = address;
    this.#ows = owsModule;
    this.#owsApiKey = owsApiKey;
  }

  /**
   * Create an OwsSigner by resolving the wallet address from OWS.
   *
   * Lazily imports @open-wallet-standard/core so the module is only required
   * when OWS is actually used (keeps it an optional peer dependency).
   */
  static async create(options: OwsSignerOptions): Promise<OwsSigner> {
    let owsModule: OwsModule;
    if (options._owsModule) {
      owsModule = options._owsModule as OwsModule;
    } else {
      try {
        // Dynamic string prevents TypeScript from statically resolving this
        // optional peer dependency at compile time.
        const moduleName = "@open-wallet-standard/core";
        owsModule = (await import(moduleName)) as unknown as OwsModule;
      } catch {
        throw new Error(
          "OWS_WALLET_ID is set but @open-wallet-standard/core is not installed. " +
            "Install it with: npm install @open-wallet-standard/core",
        );
      }
    }

    const walletInfo = owsModule.getWallet(options.walletId);
    // OWS uses "evm" as the chainId for all EVM accounts.
    const evmAccount = walletInfo.accounts.find(
      (a) => a.chainId === "evm" || a.chainId.startsWith("eip155:"),
    );
    if (!evmAccount) {
      throw new Error(
        `No EVM account found in OWS wallet '${options.walletId}'. ` +
          `Available chains: ${walletInfo.accounts.map((a) => a.chainId).join(", ") || "none"}.`,
      );
    }

    return new OwsSigner(
      options.walletId,
      evmAccount.address,
      owsModule,
      options.owsApiKey,
    );
  }

  getAddress(): string {
    return this.#address;
  }

  async signTypedData(
    domain: TypedDataDomain,
    types: TypedDataTypes,
    value: Record<string, unknown>,
  ): Promise<string> {
    // 1. Derive primaryType: first key in types that is NOT "EIP712Domain".
    const primaryType =
      Object.keys(types).filter((k) => k !== "EIP712Domain")[0] ?? "Request";

    // 2. Build EIP712Domain type array dynamically from domain object fields (G3).
    const eip712DomainType: Array<{ name: string; type: string }> = [];
    if (domain.name !== undefined)
      eip712DomainType.push({ name: "name", type: "string" });
    if (domain.version !== undefined)
      eip712DomainType.push({ name: "version", type: "string" });
    if (domain.chainId !== undefined)
      eip712DomainType.push({ name: "chainId", type: "uint256" });
    if (domain.verifyingContract !== undefined)
      eip712DomainType.push({
        name: "verifyingContract",
        type: "address",
      });

    // 3. Assemble full EIP-712 typed data structure.
    const fullTypedData = {
      types: { EIP712Domain: eip712DomainType, ...types },
      primaryType,
      domain,
      message: value,
    };

    // 4. Serialize — handle BigInt values (G4).
    const json = JSON.stringify(fullTypedData, (_key, v) =>
      typeof v === "bigint" ? v.toString() : (v as unknown),
    );

    // 5. Call OWS FFI. Chain is always "evm" for EVM signing (G2).
    const result = this.#ows.signTypedData(
      this.#walletId,
      "evm",
      json,
      this.#owsApiKey,
    );

    // 6. Concatenate r+s+v into 65-byte Ethereum signature (S4).
    const sig = result.signature.startsWith("0x")
      ? result.signature.slice(2)
      : result.signature;

    // G6: If OWS already returns r+s+v (130 hex chars), use as-is.
    if (sig.length === 130) {
      return `0x${sig}`;
    }

    // Otherwise it's r+s (128 hex chars), append v.
    const v = (result.recoveryId ?? 0) + 27;
    return `0x${sig}${v.toString(16).padStart(2, "0")}`;
  }

  /** Prevent wallet ID / key leakage in serialization. */
  toJSON(): Record<string, string> {
    return { address: this.#address, walletId: this.#walletId };
  }

  [Symbol.for("nodejs.util.inspect.custom")](): string {
    return `OwsSigner { address: '${this.#address}', wallet: '${this.#walletId}' }`;
  }
}
