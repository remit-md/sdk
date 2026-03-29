/**
 * Tests for signHash on PrivateKeySigner and the permit signature shape.
 *
 * With the server-side /permits/prepare pattern, signPermit() requires a
 * server call. These unit tests verify the local signing primitives:
 * - signHash produces valid 65-byte signatures
 * - Signature is recoverable to the signer's address
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { hashTypedData, recoverAddress } from "viem";

import { PrivateKeySigner } from "../src/signer.js";

// Anvil test wallet #0
const TEST_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const TEST_ADDR = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

// Known contract addresses (Base Sepolia)
const USDC_ADDRESS = "0x2d846325766921935f37d5b4478196d3ef93707c";
const ROUTER_ADDRESS = "0x3120f396ff6a9afc5a9d92e28796082f1429e024";

// EIP-2612 permit types
const PERMIT_TYPES = {
  Permit: [
    { name: "owner", type: "address" },
    { name: "spender", type: "address" },
    { name: "value", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

const USDC_DOMAIN = {
  name: "USD Coin",
  version: "2",
  chainId: 84532,
  verifyingContract: USDC_ADDRESS as `0x${string}`,
};

describe("PrivateKeySigner.signHash", () => {
  const signer = new PrivateKeySigner(TEST_KEY);

  it("returns valid 65-byte hex signature", async () => {
    // Compute a real EIP-712 hash to sign
    const hash = hashTypedData({
      domain: USDC_DOMAIN,
      types: PERMIT_TYPES,
      primaryType: "Permit",
      message: {
        owner: TEST_ADDR as `0x${string}`,
        spender: ROUTER_ADDRESS as `0x${string}`,
        value: BigInt(1_000_000),
        nonce: BigInt(0),
        deadline: BigInt(1999999999),
      },
    });

    const hashBytes = new Uint8Array(
      hash.slice(2).match(/.{2}/g)!.map((b) => parseInt(b, 16)),
    );

    const sig = await signer.signHash(hashBytes);
    assert.match(sig, /^0x[0-9a-f]{130}$/i, "signature must be 65 bytes hex");
  });

  it("signature recovers to the signer address", async () => {
    const hash = hashTypedData({
      domain: USDC_DOMAIN,
      types: PERMIT_TYPES,
      primaryType: "Permit",
      message: {
        owner: TEST_ADDR as `0x${string}`,
        spender: ROUTER_ADDRESS as `0x${string}`,
        value: BigInt(5_000_000),
        nonce: BigInt(0),
        deadline: BigInt(2000000000),
      },
    });

    const hashBytes = new Uint8Array(
      hash.slice(2).match(/.{2}/g)!.map((b) => parseInt(b, 16)),
    );

    const sig = await signer.signHash(hashBytes);

    const recovered = await recoverAddress({
      hash: hash as `0x${string}`,
      signature: sig as `0x${string}`,
    });

    assert.equal(
      recovered.toLowerCase(),
      TEST_ADDR.toLowerCase(),
      "recovered address must match signer",
    );
  });

  it("different hashes produce different signatures", async () => {
    const hash1 = hashTypedData({
      domain: USDC_DOMAIN,
      types: PERMIT_TYPES,
      primaryType: "Permit",
      message: {
        owner: TEST_ADDR as `0x${string}`,
        spender: ROUTER_ADDRESS as `0x${string}`,
        value: BigInt(1_000_000),
        nonce: BigInt(0),
        deadline: BigInt(1999999999),
      },
    });

    const hash2 = hashTypedData({
      domain: USDC_DOMAIN,
      types: PERMIT_TYPES,
      primaryType: "Permit",
      message: {
        owner: TEST_ADDR as `0x${string}`,
        spender: ROUTER_ADDRESS as `0x${string}`,
        value: BigInt(1_000_000),
        nonce: BigInt(1),
        deadline: BigInt(1999999999),
      },
    });

    const toBytes = (h: string) => new Uint8Array(
      h.slice(2).match(/.{2}/g)!.map((b) => parseInt(b, 16)),
    );

    const sig1 = await signer.signHash(toBytes(hash1));
    const sig2 = await signer.signHash(toBytes(hash2));

    assert.notEqual(sig1, sig2, "different hashes must produce different signatures");
  });
});

describe("PrivateKeySigner.getAddress", () => {
  it("returns checksummed address", () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    assert.equal(signer.getAddress(), TEST_ADDR);
  });
});
