import { privateKeyToAccount } from "viem/accounts";
import type { PrivateKeyAccount, SignTypedDataParameters } from "viem/accounts";

/** EIP-712 typed data domain. */
export interface TypedDataDomain {
  name: string;
  version: string;
  chainId?: number;
  verifyingContract?: string;
}

/** EIP-712 type definitions. */
export type TypedDataTypes = Record<string, Array<{ name: string; type: string }>>;

/** Pluggable signing interface. Implementations must isolate key material. */
export interface Signer {
  /** Sign EIP-712 typed data and return hex signature. */
  signTypedData(
    domain: TypedDataDomain,
    types: TypedDataTypes,
    value: Record<string, unknown>,
  ): Promise<string>;

  /** Sign a raw 32-byte hash and return the 0x-prefixed hex signature (65 bytes: r+s+v). */
  signHash(hash: Uint8Array): Promise<string>;

  /** Return the checksummed public address. */
  getAddress(): string;
}

/** Default signer: raw private key via viem. Key is held in closure, never exposed. */
export class PrivateKeySigner implements Signer {
  readonly #account: PrivateKeyAccount;

  constructor(privateKey: string) {
    // Normalise: ensure 0x prefix
    const hex = (privateKey.startsWith("0x") ? privateKey : `0x${privateKey}`) as `0x${string}`;
    this.#account = privateKeyToAccount(hex);
  }

  /** Create from hex private key string. */
  static fromHex(privateKey: string): PrivateKeySigner {
    return new PrivateKeySigner(privateKey);
  }

  async signTypedData(
    domain: TypedDataDomain,
    types: TypedDataTypes,
    value: Record<string, unknown>,
  ): Promise<string> {
    const primaryType = Object.keys(types).filter((k) => k !== "EIP712Domain")[0] ?? "Request";
    // Cast through unknown to satisfy viem's highly-parameterized overloads
    return this.#account.signTypedData({
      domain,
      types,
      primaryType,
      message: value,
    } as unknown as SignTypedDataParameters);
  }

  async signHash(hash: Uint8Array): Promise<string> {
    return this.#account.sign({ hash: `0x${Buffer.from(hash).toString("hex")}` as `0x${string}` });
  }

  getAddress(): string {
    return this.#account.address;
  }

  /** Prevent key leakage in serialization. */
  toJSON(): Record<string, string> {
    return { address: this.#account.address };
  }

  [Symbol.for("nodejs.util.inspect.custom")](): string {
    return `PrivateKeySigner { address: '${this.#account.address}' }`;
  }
}
