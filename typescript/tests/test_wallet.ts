import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { inspect } from "node:util";

import { Wallet } from "../src/wallet.js";
import { PrivateKeySigner } from "../src/signer.js";

const TEST_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const TEST_ADDR = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

describe("Wallet construction", () => {
  it("constructs from private key", () => {
    const wallet = new Wallet({ privateKey: TEST_KEY });
    assert.equal(wallet.address.toLowerCase(), TEST_ADDR.toLowerCase());
  });

  it("constructs from custom Signer", () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    const wallet = new Wallet({ signer });
    assert.equal(wallet.address.toLowerCase(), TEST_ADDR.toLowerCase());
  });

  it("throws without key or signer", () => {
    assert.throws(() => new Wallet({}), /requires privateKey or signer/);
  });

  it("Wallet.create() generates unique addresses", () => {
    const a = Wallet.create();
    const b = Wallet.create();
    assert.notEqual(a.address, b.address);
  });

  it("Wallet.fromEnv() throws when REMITMD_KEY not set", () => {
    const saved = process.env["REMITMD_KEY"];
    delete process.env["REMITMD_KEY"];
    try {
      assert.throws(() => Wallet.fromEnv(), /REMITMD_KEY/);
    } finally {
      if (saved) process.env["REMITMD_KEY"] = saved;
    }
  });

  it("Wallet.fromEnv() succeeds when REMITMD_KEY is set", () => {
    process.env["REMITMD_KEY"] = TEST_KEY;
    try {
      const wallet = Wallet.fromEnv();
      assert.equal(wallet.address.toLowerCase(), TEST_ADDR.toLowerCase());
    } finally {
      delete process.env["REMITMD_KEY"];
    }
  });
});

describe("Wallet security", () => {
  it("toJSON does not expose private key", () => {
    const wallet = new Wallet({ privateKey: TEST_KEY });
    const json = JSON.stringify(wallet);
    assert(!json.includes(TEST_KEY), "private key must not appear in JSON");
    assert(!json.includes("ac0974"), "private key fragment must not appear in JSON");
  });

  it("inspect does not expose private key", () => {
    const wallet = new Wallet({ privateKey: TEST_KEY });
    const repr = inspect(wallet);
    assert(!repr.includes("ac0974"), "private key must not appear in inspect output");
  });

  it("PrivateKeySigner toJSON does not expose key", () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    const json = JSON.stringify(signer);
    assert(!json.includes("ac0974"), "private key must not appear in signer JSON");
    assert(json.includes(TEST_ADDR.toLowerCase()) || json.includes("0xf39"), "address should be present");
  });
});

describe("PrivateKeySigner", () => {
  it("accepts key with 0x prefix", () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    assert.equal(signer.getAddress().toLowerCase(), TEST_ADDR.toLowerCase());
  });

  it("accepts key without 0x prefix", () => {
    const signer = new PrivateKeySigner(TEST_KEY.slice(2));
    assert.equal(signer.getAddress().toLowerCase(), TEST_ADDR.toLowerCase());
  });

  it("fromHex factory works", () => {
    const signer = PrivateKeySigner.fromHex(TEST_KEY);
    assert.equal(signer.getAddress().toLowerCase(), TEST_ADDR.toLowerCase());
  });

  it("signs typed data and returns hex string", async () => {
    const signer = new PrivateKeySigner(TEST_KEY);
    const sig = await signer.signTypedData(
      { name: "Test", version: "1" },
      { Request: [{ name: "value", type: "string" }] },
      { value: "hello" },
    );
    assert(sig.startsWith("0x"), "signature should be hex");
    assert(sig.length >= 130, "signature should be at least 65 bytes");
  });
});
