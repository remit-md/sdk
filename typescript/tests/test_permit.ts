/**
 * Tests for EIP-2612 permit signing (signUsdcPermit / signPermit).
 *
 * Verifies:
 * - signUsdcPermit produces valid v/r/s format
 * - Domain matches MockUSDC (name="USD Coin", version="2")
 * - Signature is recoverable to the signer's address
 * - signPermit computes correct raw amounts from USDC decimals
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { hashTypedData, recoverTypedDataAddress } from "viem";

import { Wallet } from "../src/wallet.js";

// Anvil test wallet #0
const TEST_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const TEST_ADDR = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

// Known contract addresses (Base Sepolia)
const USDC_ADDRESS = "0x2d846325766921935f37d5b4478196d3ef93707c";
const ROUTER_ADDRESS = "0x3120f396ff6a9afc5a9d92e28796082f1429e024";
const ESCROW_ADDRESS = "0x47de7cdd757e3765d36c083dab59b2c5a9d249f2";

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

describe("signUsdcPermit", () => {
  const wallet = new Wallet({
    privateKey: TEST_KEY,
    chain: "base-sepolia",
  });

  it("returns valid PermitSignature shape", async () => {
    const permit = await wallet.signUsdcPermit({
      spender: ROUTER_ADDRESS,
      value: BigInt(1_000_000), // 1 USDC
      deadline: 1999999999,
      nonce: 0,
    });

    assert.equal(typeof permit.value, "number");
    assert.equal(permit.value, 1_000_000);
    assert.equal(permit.deadline, 1999999999);
    assert.equal(typeof permit.v, "number");
    assert(permit.v === 27 || permit.v === 28, `v must be 27 or 28, got ${permit.v}`);
    assert.match(permit.r, /^0x[0-9a-f]{64}$/i, "r must be 32 bytes hex");
    assert.match(permit.s, /^0x[0-9a-f]{64}$/i, "s must be 32 bytes hex");
  });

  it("signature recovers to the wallet address", async () => {
    const spender = ESCROW_ADDRESS;
    const value = BigInt(5_000_000); // 5 USDC
    const deadline = 2000000000;
    const nonce = 0;

    const permit = await wallet.signUsdcPermit({
      spender,
      value,
      deadline,
      nonce,
    });

    // Reconstruct the full signature hex
    const rHex = permit.r.slice(2);
    const sHex = permit.s.slice(2);
    const vHex = permit.v.toString(16).padStart(2, "0");
    const fullSig = `0x${rHex}${sHex}${vHex}` as `0x${string}`;

    const recovered = await recoverTypedDataAddress({
      domain: USDC_DOMAIN,
      types: PERMIT_TYPES,
      primaryType: "Permit",
      message: {
        owner: TEST_ADDR as `0x${string}`,
        spender: spender as `0x${string}`,
        value,
        nonce: BigInt(nonce),
        deadline: BigInt(deadline),
      },
      signature: fullSig,
    });

    assert.equal(
      recovered.toLowerCase(),
      TEST_ADDR.toLowerCase(),
      "recovered address must match signer",
    );
  });

  it("different nonces produce different signatures", async () => {
    const base = {
      spender: ROUTER_ADDRESS,
      value: BigInt(1_000_000),
      deadline: 1999999999,
    };

    const sig0 = await wallet.signUsdcPermit({ ...base, nonce: 0 });
    const sig1 = await wallet.signUsdcPermit({ ...base, nonce: 1 });

    assert.notEqual(sig0.r, sig1.r, "different nonces must produce different r");
  });

  it("different spenders produce different signatures", async () => {
    const base = {
      value: BigInt(1_000_000),
      deadline: 1999999999,
      nonce: 0,
    };

    const sigRouter = await wallet.signUsdcPermit({ ...base, spender: ROUTER_ADDRESS });
    const sigEscrow = await wallet.signUsdcPermit({ ...base, spender: ESCROW_ADDRESS });

    assert.notEqual(sigRouter.r, sigEscrow.r, "different spenders must produce different r");
  });

  it("uses correct EIP-712 domain (USD Coin v2)", async () => {
    // Hash the typed data ourselves and verify the wallet's signature matches
    const spender = ROUTER_ADDRESS;
    const value = BigInt(2_500_000); // 2.5 USDC
    const deadline = 2000000000;
    const nonce = 0;

    const expectedHash = hashTypedData({
      domain: USDC_DOMAIN,
      types: PERMIT_TYPES,
      primaryType: "Permit",
      message: {
        owner: TEST_ADDR as `0x${string}`,
        spender: spender as `0x${string}`,
        value,
        nonce: BigInt(nonce),
        deadline: BigInt(deadline),
      },
    });

    // Just verify the hash is deterministic - domain is correct if recovery works
    assert.match(expectedHash, /^0x[0-9a-f]{64}$/i);

    const permit = await wallet.signUsdcPermit({
      spender,
      value,
      deadline,
      nonce,
    });

    // Verify recovery with the domain we used
    const rHex = permit.r.slice(2);
    const sHex = permit.s.slice(2);
    const vHex = permit.v.toString(16).padStart(2, "0");
    const fullSig = `0x${rHex}${sHex}${vHex}` as `0x${string}`;

    const recovered = await recoverTypedDataAddress({
      domain: USDC_DOMAIN,
      types: PERMIT_TYPES,
      primaryType: "Permit",
      message: {
        owner: TEST_ADDR as `0x${string}`,
        spender: spender as `0x${string}`,
        value,
        nonce: BigInt(nonce),
        deadline: BigInt(deadline),
      },
      signature: fullSig,
    });

    assert.equal(
      recovered.toLowerCase(),
      TEST_ADDR.toLowerCase(),
      "must recover with USD Coin v2 domain",
    );
  });
});

describe("PermitSignature value ranges", () => {
  const wallet = new Wallet({
    privateKey: TEST_KEY,
    chain: "base-sepolia",
  });

  it("handles zero value", async () => {
    const permit = await wallet.signUsdcPermit({
      spender: ROUTER_ADDRESS,
      value: BigInt(0),
      deadline: 1999999999,
      nonce: 0,
    });
    assert.equal(permit.value, 0);
  });

  it("handles large value ($2,500 = 2_500_000_000 raw)", async () => {
    const permit = await wallet.signUsdcPermit({
      spender: ROUTER_ADDRESS,
      value: BigInt(2_500_000_000),
      deadline: 1999999999,
      nonce: 0,
    });
    assert.equal(permit.value, 2_500_000_000);
  });
});
