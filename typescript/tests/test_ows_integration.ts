/**
 * Integration test: OwsSigner with REAL @open-wallet-standard/core.
 *
 * Skips automatically if OWS native binaries are not available (e.g. Windows).
 * In CI (Linux), OWS is installed as a step before this test runs.
 *
 * What it tests:
 *   1. Create a wallet via OWS
 *   2. Construct OwsSigner from that wallet
 *   3. Sign EIP-712 typed data
 *   4. Verify the signature recovers to the wallet address (ecrecover)
 */

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { verifyTypedData } from "viem";

// Try to load OWS - skip all tests if unavailable.
let ows: {
  createWallet: (name: string) => { id: string; name: string; accounts: Array<{ chainId: string; address: string; derivationPath: string }>; createdAt: string };
  deleteWallet: (nameOrId: string) => void;
} | null = null;

let owsAvailable = false;
try {
  const moduleName = "@open-wallet-standard/core";
  ows = (await import(moduleName)) as unknown as typeof ows;
  owsAvailable = true;
} catch {
  // OWS not installed - tests will be skipped
}

describe("OwsSigner integration (real OWS)", { skip: !owsAvailable && "OWS not installed" }, () => {
  const walletName = `remit-test-${Date.now()}`;
  let walletAddress: string;

  before(() => {
    if (!ows) throw new Error("OWS not available");
    const wallet = ows.createWallet(walletName);
    const evmAccount = wallet.accounts.find(
      (a) => a.chainId === "evm" || a.chainId.startsWith("eip155:"),
    );
    if (!evmAccount) throw new Error("No EVM account in created wallet");
    walletAddress = evmAccount.address;
  });

  // Cleanup after all tests
  after(() => {
    if (ows) {
      try {
        ows.deleteWallet(walletName);
      } catch {
        // Best-effort cleanup
      }
    }
  });

  it("creates OwsSigner from real OWS wallet", async () => {
    const { OwsSigner } = await import("../src/ows-signer.js");
    const signer = await OwsSigner.create({ walletId: walletName });
    assert.equal(signer.getAddress(), walletAddress);
  });

  it("signs EIP-712 typed data and signature recovers correctly", async () => {
    const { OwsSigner } = await import("../src/ows-signer.js");
    const signer = await OwsSigner.create({ walletId: walletName });

    const domain = {
      name: "USD Coin",
      version: "2",
      chainId: 84532,
      verifyingContract: "0x2d846325766921935f37d5b4478196d3ef93707c" as `0x${string}`,
    };

    const types = {
      Permit: [
        { name: "owner", type: "address" },
        { name: "spender", type: "address" },
        { name: "value", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    } as const;

    const message = {
      owner: walletAddress as `0x${string}`,
      spender: "0x3120f396ff6a9afc5a9d92e28796082f1429e024" as `0x${string}`,
      value: BigInt(1_000_000),
      nonce: BigInt(0),
      deadline: BigInt(Math.floor(Date.now() / 1000) + 3600),
    };

    const signature = await signer.signTypedData(
      domain,
      types as unknown as Record<string, Array<{ name: string; type: string }>>,
      message as unknown as Record<string, unknown>,
    );

    // Verify: 132 chars = "0x" + 130 hex
    assert.equal(signature.length, 132, `signature should be 132 chars, got ${signature.length}`);
    assert.ok(signature.startsWith("0x"), "signature should start with 0x");

    // Ecrecover: verify the signature was made by the wallet address
    const valid = await verifyTypedData({
      address: walletAddress as `0x${string}`,
      domain,
      types,
      primaryType: "Permit",
      message,
      signature: signature as `0x${string}`,
    });

    assert.ok(valid, "ecrecover must match the wallet address");
  });

  it("Wallet.withOws() creates a working wallet with real OWS", async () => {
    // Set env vars for withOws()
    const savedWalletId = process.env["OWS_WALLET_ID"];
    const savedKey = process.env["REMITMD_KEY"];
    process.env["OWS_WALLET_ID"] = walletName;
    delete process.env["REMITMD_KEY"];

    try {
      const { Wallet } = await import("../src/wallet.js");
      const wallet = await Wallet.withOws();
      assert.equal(wallet.address, walletAddress);
    } finally {
      if (savedWalletId !== undefined) process.env["OWS_WALLET_ID"] = savedWalletId;
      else delete process.env["OWS_WALLET_ID"];
      if (savedKey !== undefined) process.env["REMITMD_KEY"] = savedKey;
      else delete process.env["REMITMD_KEY"];
    }
  });
});
