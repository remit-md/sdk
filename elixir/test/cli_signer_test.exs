defmodule RemitMd.CliSignerTest do
  use ExUnit.Case, async: false

  alias RemitMd.CliSigner

  # ─── available?/1 ──────────────────────────────────────────────────────────

  describe "available?/1" do
    setup do
      on_exit(fn ->
        System.delete_env("REMIT_SIGNER_KEY")
      end)

      :ok
    end

    test "returns false when CLI binary not found" do
      refute CliSigner.available?("nonexistent_binary_xyz")
    end

    test "returns false when REMIT_SIGNER_KEY is not set" do
      System.delete_env("REMIT_SIGNER_KEY")
      # Even if CLI exists, password must be set
      # (keystore also likely missing in test env)
      refute CliSigner.available?()
    end
  end

  # ─── new/1 ─────────────────────────────────────────────────────────────────

  describe "new/1" do
    test "returns error when CLI binary not found" do
      assert {:error, msg} = CliSigner.new("nonexistent_binary_xyz")
      assert String.contains?(msg, "CLI not found")
    end
  end

  # ─── struct and protocols ──────────────────────────────────────────────────

  describe "struct and protocols" do
    test "inspect does not leak sensitive info" do
      signer = %CliSigner{address: "0xDeAdBeEf00000000000000000000000000000001", cli_path: "remit"}
      inspected = inspect(signer)

      assert String.contains?(inspected, "CliSigner")
      assert String.contains?(inspected, "0xDeAdBeEf00000000000000000000000000000001")
      refute String.contains?(inspected, "cli_path")
    end

    test "to_string does not leak sensitive info" do
      signer = %CliSigner{address: "0xDeAdBeEf00000000000000000000000000000001", cli_path: "remit"}
      stringified = to_string(signer)

      assert String.contains?(stringified, "CliSigner")
      assert String.contains?(stringified, "0xDeAdBeEf00000000000000000000000000000001")
    end

    test "address/1 returns cached address" do
      signer = %CliSigner{address: "0xDeAdBeEf00000000000000000000000000000001", cli_path: "remit"}
      assert CliSigner.address(signer) == "0xDeAdBeEf00000000000000000000000000000001"
    end
  end

  # ─── from_env integration ──────────────────────────────────────────────────

  describe "from_env integration" do
    setup do
      on_exit(fn ->
        System.delete_env("REMITMD_KEY")
        System.delete_env("REMITMD_PRIVATE_KEY")
        System.delete_env("REMITMD_CHAIN")
        System.delete_env("REMITMD_API_URL")
        System.delete_env("REMITMD_ROUTER_ADDRESS")
        System.delete_env("REMIT_SIGNER_KEY")
      end)

      :ok
    end

    test "from_env raises clear error with install instructions when no credentials set" do
      System.delete_env("REMITMD_KEY")
      System.delete_env("REMITMD_PRIVATE_KEY")
      System.delete_env("REMIT_SIGNER_KEY")

      error = assert_raise RemitMd.Error, ~r/No signing credentials found/, fn ->
        RemitMd.Wallet.from_env()
      end

      assert String.contains?(error.message, "brew install")
      assert String.contains?(error.message, "curl -fsSL")
      assert String.contains?(error.message, "winget install")
    end

    test "from_env falls back to REMITMD_KEY when CLI not available" do
      System.delete_env("REMIT_SIGNER_KEY")
      # Use a known test private key
      System.put_env("REMITMD_KEY", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")

      wallet = RemitMd.Wallet.from_env()
      assert %RemitMd.PrivateKeySigner{} = wallet.signer
      assert wallet.address != nil
    end
  end
end
