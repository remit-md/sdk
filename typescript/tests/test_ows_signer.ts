import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { inspect } from "node:util";

import { OwsSigner } from "../src/ows-signer.js";
import { Wallet } from "../src/wallet.js";

// ─── Mock OWS Module ──────────────────────────────────────────────────────────

const MOCK_ADDRESS = "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD50";
const MOCK_WALLET_ID = "remit-test-agent";

/** r||s (128 hex chars, no v) - OWS returns this when recoveryId is separate. */
const MOCK_SIG_RS =
  "a".repeat(64) + "b".repeat(64); // 128 hex

/** r||s||v (130 hex chars) - OWS returns this when v is already appended. */
const MOCK_SIG_RSV =
  "a".repeat(64) + "b".repeat(64) + "1b"; // 130 hex

function createMockOws(overrides?: {
  signature?: string;
  recoveryId?: number;
  accounts?: Array<{ chainId: string; address: string; derivationPath: string }>;
  signCapture?: { calls: Array<{ wallet: string; chain: string; json: string; passphrase?: string }> };
}) {
  const signCapture = overrides?.signCapture ?? { calls: [] };
  return {
    getWallet(nameOrId: string) {
      return {
        id: "uuid-" + nameOrId,
        name: nameOrId,
        accounts: overrides?.accounts ?? [
          { chainId: "evm", address: MOCK_ADDRESS, derivationPath: "m/44'/60'/0'/0/0" },
        ],
        createdAt: "2026-01-01T00:00:00Z",
      };
    },
    signTypedData(
      wallet: string,
      chain: string,
      typedDataJson: string,
      passphrase?: string,
    ) {
      signCapture.calls.push({ wallet, chain, json: typedDataJson, passphrase });
      return {
        signature: overrides?.signature ?? MOCK_SIG_RS,
        recoveryId: overrides?.recoveryId ?? 0,
      };
    },
  };
}

// ─── OwsSigner.create() ───────────────────────────────────────────────────────

describe("OwsSigner.create()", () => {
  it("constructs successfully with mock OWS module", async () => {
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      _owsModule: createMockOws(),
    });
    assert.equal(signer.getAddress(), MOCK_ADDRESS);
  });

  it("caches address from getWallet at construction time", async () => {
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      _owsModule: createMockOws(),
    });
    // getAddress() is sync and always returns the same value
    assert.equal(signer.getAddress(), MOCK_ADDRESS);
    assert.equal(signer.getAddress(), MOCK_ADDRESS);
  });

  it("finds evm account by chainId 'evm'", async () => {
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      _owsModule: createMockOws({
        accounts: [
          { chainId: "solana", address: "SolAddr", derivationPath: "m/44'/501'/0'/0/0" },
          { chainId: "evm", address: MOCK_ADDRESS, derivationPath: "m/44'/60'/0'/0/0" },
        ],
      }),
    });
    assert.equal(signer.getAddress(), MOCK_ADDRESS);
  });

  it("finds evm account by chainId starting with 'eip155:'", async () => {
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      _owsModule: createMockOws({
        accounts: [
          { chainId: "eip155:8453", address: MOCK_ADDRESS, derivationPath: "m/44'/60'/0'/0/0" },
        ],
      }),
    });
    assert.equal(signer.getAddress(), MOCK_ADDRESS);
  });

  it("throws when no EVM account exists", async () => {
    await assert.rejects(
      () =>
        OwsSigner.create({
          walletId: MOCK_WALLET_ID,
          _owsModule: createMockOws({
            accounts: [{ chainId: "solana", address: "SolAddr", derivationPath: "" }],
          }),
        }),
      /No EVM account found/,
    );
  });

  it("throws when OWS module is not installed (no _owsModule)", async (t) => {
    // In CI, OWS is installed via peerDependencies - skip this test.
    // The error path is structurally validated: try/catch around dynamic import.
    try {
      const m = "@open-wallet-standard/core";
      await import(m);
      t.skip("OWS is installed in this environment");
      return;
    } catch {
      // OWS not available - test the error path
    }
    await assert.rejects(
      () => OwsSigner.create({ walletId: MOCK_WALLET_ID }),
      /@open-wallet-standard\/core is not installed/,
    );
  });
});

// ─── signTypedData ────────────────────────────────────────────────────────────

describe("OwsSigner.signTypedData()", () => {
  it("builds correct EIP-712 JSON with EIP712Domain type", async () => {
    const capture = { calls: [] as Array<{ wallet: string; chain: string; json: string; passphrase?: string }> };
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      _owsModule: createMockOws({ signCapture: capture }),
    });

    await signer.signTypedData(
      { name: "USD Coin", version: "2", chainId: 8453, verifyingContract: "0xUSDC" },
      { Permit: [{ name: "owner", type: "address" }, { name: "value", type: "uint256" }] },
      { owner: "0xABC", value: "1000000" },
    );

    assert.equal(capture.calls.length, 1);
    const parsed = JSON.parse(capture.calls[0].json);

    // EIP712Domain should be injected
    assert.ok(parsed.types.EIP712Domain, "EIP712Domain type must be present");
    assert.equal(parsed.types.EIP712Domain.length, 4); // name, version, chainId, verifyingContract

    // primaryType should be derived
    assert.equal(parsed.primaryType, "Permit");

    // domain should be passed through
    assert.equal(parsed.domain.name, "USD Coin");
    assert.equal(parsed.domain.chainId, 8453);

    // message should be the value
    assert.equal(parsed.message.owner, "0xABC");
  });

  it("derives primaryType from first non-EIP712Domain key", async () => {
    const capture = { calls: [] as Array<{ wallet: string; chain: string; json: string; passphrase?: string }> };
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      _owsModule: createMockOws({ signCapture: capture }),
    });

    await signer.signTypedData(
      { name: "remit.md", version: "0.1" },
      { APIRequest: [{ name: "method", type: "string" }] },
      { method: "POST" },
    );

    const parsed = JSON.parse(capture.calls[0].json);
    assert.equal(parsed.primaryType, "APIRequest");
  });

  it("builds EIP712Domain only from present domain fields", async () => {
    const capture = { calls: [] as Array<{ wallet: string; chain: string; json: string; passphrase?: string }> };
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      _owsModule: createMockOws({ signCapture: capture }),
    });

    // Domain with only name and version (no chainId, no verifyingContract)
    await signer.signTypedData(
      { name: "Test", version: "1" },
      { Msg: [{ name: "data", type: "string" }] },
      { data: "hello" },
    );

    const parsed = JSON.parse(capture.calls[0].json);
    assert.equal(parsed.types.EIP712Domain.length, 2); // only name + version
    assert.deepEqual(
      parsed.types.EIP712Domain.map((f: { name: string }) => f.name),
      ["name", "version"],
    );
  });

  it("always passes 'evm' as chain to OWS (G2)", async () => {
    const capture = { calls: [] as Array<{ wallet: string; chain: string; json: string; passphrase?: string }> };
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      chain: "base-sepolia",
      _owsModule: createMockOws({ signCapture: capture }),
    });

    await signer.signTypedData(
      { name: "Test", version: "1" },
      { Msg: [{ name: "x", type: "uint256" }] },
      { x: 42 },
    );

    assert.equal(capture.calls[0].chain, "evm");
  });

  it("passes OWS API key as passphrase", async () => {
    const capture = { calls: [] as Array<{ wallet: string; chain: string; json: string; passphrase?: string }> };
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      owsApiKey: "ows_key_test123",
      _owsModule: createMockOws({ signCapture: capture }),
    });

    await signer.signTypedData(
      { name: "T", version: "1" },
      { M: [{ name: "x", type: "uint256" }] },
      { x: 1 },
    );

    assert.equal(capture.calls[0].passphrase, "ows_key_test123");
  });

  it("does not include passphrase in JSON payload", async () => {
    const capture = { calls: [] as Array<{ wallet: string; chain: string; json: string; passphrase?: string }> };
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      owsApiKey: "ows_key_secret",
      _owsModule: createMockOws({ signCapture: capture }),
    });

    await signer.signTypedData(
      { name: "T", version: "1" },
      { M: [{ name: "x", type: "uint256" }] },
      { x: 1 },
    );

    assert(!capture.calls[0].json.includes("ows_key_secret"), "API key must not appear in JSON");
  });
});

// ─── Signature concatenation ──────────────────────────────────────────────────

describe("OwsSigner signature concatenation", () => {
  it("appends v=27 (recoveryId=0) to 128-char r||s signature", async () => {
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      _owsModule: createMockOws({ signature: MOCK_SIG_RS, recoveryId: 0 }),
    });

    const sig = await signer.signTypedData(
      { name: "T", version: "1" },
      { M: [{ name: "x", type: "uint256" }] },
      { x: 1 },
    );

    assert.equal(sig.length, 132); // "0x" + 130 hex
    assert.ok(sig.startsWith("0x"));
    assert.equal(sig.slice(-2), "1b"); // v=27 = 0x1b
  });

  it("appends v=28 (recoveryId=1) to 128-char r||s signature", async () => {
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      _owsModule: createMockOws({ signature: MOCK_SIG_RS, recoveryId: 1 }),
    });

    const sig = await signer.signTypedData(
      { name: "T", version: "1" },
      { M: [{ name: "x", type: "uint256" }] },
      { x: 1 },
    );

    assert.equal(sig.slice(-2), "1c"); // v=28 = 0x1c
  });

  it("returns 130-char r||s||v signature as-is (G6)", async () => {
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      _owsModule: createMockOws({ signature: MOCK_SIG_RSV }),
    });

    const sig = await signer.signTypedData(
      { name: "T", version: "1" },
      { M: [{ name: "x", type: "uint256" }] },
      { x: 1 },
    );

    assert.equal(sig.length, 132); // "0x" + 130
    assert.equal(sig, `0x${MOCK_SIG_RSV}`);
  });

  it("handles 0x-prefixed signature from OWS", async () => {
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      _owsModule: createMockOws({ signature: `0x${MOCK_SIG_RS}`, recoveryId: 0 }),
    });

    const sig = await signer.signTypedData(
      { name: "T", version: "1" },
      { M: [{ name: "x", type: "uint256" }] },
      { x: 1 },
    );

    assert.equal(sig.length, 132);
    assert.ok(sig.startsWith("0x"));
  });

  it("defaults recoveryId to 0 when undefined", async () => {
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      _owsModule: createMockOws({ signature: MOCK_SIG_RS, recoveryId: undefined }),
    });

    const sig = await signer.signTypedData(
      { name: "T", version: "1" },
      { M: [{ name: "x", type: "uint256" }] },
      { x: 1 },
    );

    assert.equal(sig.slice(-2), "1b"); // v=27
  });
});

// ─── BigInt serialization ─────────────────────────────────────────────────────

describe("OwsSigner BigInt handling (G4)", () => {
  it("serializes BigInt values in message to strings", async () => {
    const capture = { calls: [] as Array<{ wallet: string; chain: string; json: string; passphrase?: string }> };
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      _owsModule: createMockOws({ signCapture: capture }),
    });

    await signer.signTypedData(
      { name: "USD Coin", version: "2", chainId: 8453, verifyingContract: "0xUSDC" },
      { Permit: [{ name: "value", type: "uint256" }, { name: "deadline", type: "uint256" }] },
      { value: BigInt("1000000000000000000"), deadline: BigInt(1711387200) },
    );

    const parsed = JSON.parse(capture.calls[0].json);
    assert.equal(parsed.message.value, "1000000000000000000");
    assert.equal(parsed.message.deadline, "1711387200");
  });
});

// ─── Security / serialization ─────────────────────────────────────────────────

describe("OwsSigner security", () => {
  it("toJSON exposes address and walletId only", async () => {
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      owsApiKey: "ows_key_secret",
      _owsModule: createMockOws(),
    });

    const json = JSON.parse(JSON.stringify(signer));
    assert.equal(json.address, MOCK_ADDRESS);
    assert.equal(json.walletId, MOCK_WALLET_ID);
    assert.equal(Object.keys(json).length, 2);
  });

  it("toJSON does not expose API key", async () => {
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      owsApiKey: "ows_key_secret",
      _owsModule: createMockOws(),
    });

    const str = JSON.stringify(signer);
    assert(!str.includes("ows_key_secret"), "API key must not appear in JSON");
  });

  it("inspect output is safe", async () => {
    const signer = await OwsSigner.create({
      walletId: MOCK_WALLET_ID,
      owsApiKey: "ows_key_secret",
      _owsModule: createMockOws(),
    });

    const repr = inspect(signer);
    assert(repr.includes(MOCK_ADDRESS), "address should be in inspect");
    assert(repr.includes(MOCK_WALLET_ID), "walletId should be in inspect");
    assert(!repr.includes("ows_key_secret"), "API key must not appear in inspect");
  });
});

// ─── Wallet.withOws() ─────────────────────────────────────────────────────────

describe("Wallet.withOws()", () => {
  it("throws when neither OWS_WALLET_ID nor REMITMD_KEY is set", async () => {
    const saved = {
      ows: process.env["OWS_WALLET_ID"],
      key: process.env["REMITMD_KEY"],
    };
    delete process.env["OWS_WALLET_ID"];
    delete process.env["REMITMD_KEY"];
    try {
      await assert.rejects(() => Wallet.withOws(), /OWS_WALLET_ID or REMITMD_KEY/);
    } finally {
      if (saved.ows !== undefined) process.env["OWS_WALLET_ID"] = saved.ows;
      if (saved.key !== undefined) process.env["REMITMD_KEY"] = saved.key;
    }
  });

  it("falls back to REMITMD_KEY when OWS_WALLET_ID is not set", async () => {
    const saved = {
      ows: process.env["OWS_WALLET_ID"],
      key: process.env["REMITMD_KEY"],
    };
    delete process.env["OWS_WALLET_ID"];
    process.env["REMITMD_KEY"] = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    try {
      const wallet = await Wallet.withOws();
      assert.equal(wallet.address.toLowerCase(), "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266");
    } finally {
      if (saved.ows !== undefined) process.env["OWS_WALLET_ID"] = saved.ows;
      else delete process.env["OWS_WALLET_ID"];
      if (saved.key !== undefined) process.env["REMITMD_KEY"] = saved.key;
      else delete process.env["REMITMD_KEY"];
    }
  });

  it("Wallet.fromEnv() throws helpful error when OWS_WALLET_ID is set but no key", () => {
    const saved = {
      ows: process.env["OWS_WALLET_ID"],
      key: process.env["REMITMD_KEY"],
    };
    process.env["OWS_WALLET_ID"] = "remit-test";
    delete process.env["REMITMD_KEY"];
    try {
      assert.throws(() => Wallet.fromEnv(), /Wallet\.withOws/);
    } finally {
      if (saved.ows !== undefined) process.env["OWS_WALLET_ID"] = saved.ows;
      else delete process.env["OWS_WALLET_ID"];
      if (saved.key !== undefined) process.env["REMITMD_KEY"] = saved.key;
      else delete process.env["REMITMD_KEY"];
    }
  });
});
