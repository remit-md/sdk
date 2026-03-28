# frozen_string_literal: true

require "spec_helper"

# rubocop:disable Metrics/BlockLength
RSpec.describe Remitmd::CliSigner do
  MOCK_ADDRESS   = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  MOCK_SIGNATURE = "0x#{"ab" * 32}#{"cd" * 32}1b"

  # ── Stub helpers ────────────────────────────────────────────────────────────

  # Stub Open3.capture3 to return controlled output for specific CLI invocations.
  def stub_cli(command_suffix, stdout: "", stderr: "", success: true)
    status = instance_double(Process::Status, success?: success)
    allow(Open3).to receive(:capture3).with("remit", *command_suffix, anything).and_return(
      [stdout, stderr, status]
    )
  end

  def stub_cli_address(address: MOCK_ADDRESS, stderr: "", success: true)
    status = instance_double(Process::Status, success?: success)
    allow(Open3).to receive(:capture3).with("remit", "address", stdin_data: "").and_return(
      [address + "\n", stderr, status]
    )
  end

  def stub_cli_sign(signature: MOCK_SIGNATURE, stderr: "", success: true)
    status = instance_double(Process::Status, success?: success)
    allow(Open3).to receive(:capture3).with("remit", "sign", "--digest", anything).and_return(
      [signature + "\n", stderr, status]
    )
  end

  # ── Happy path ──────────────────────────────────────────────────────────────

  describe "happy path" do
    before do
      stub_cli_address
      stub_cli_sign
    end

    it "fetches and caches the address on construction" do
      signer = described_class.new
      expect(signer.address).to eq(MOCK_ADDRESS)
    end

    it "signs a digest and returns the signature" do
      signer = described_class.new
      digest = "\x00" * 32
      sig = signer.sign(digest)
      expect(sig).to eq(MOCK_SIGNATURE)
    end

    it "pipes the hex-encoded digest to stdin" do
      signer = described_class.new
      digest = ("\xab" * 32).b
      expected_hex = "ab" * 32

      status = instance_double(Process::Status, success?: true)
      expect(Open3).to receive(:capture3).with(
        "remit", "sign", "--digest", stdin_data: expected_hex
      ).and_return([MOCK_SIGNATURE + "\n", "", status])

      signer.sign(digest)
    end
  end

  # ── CLI not found ───────────────────────────────────────────────────────────

  describe "CLI not found" do
    it "raises SERVER_ERROR when remit binary is missing" do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

      expect {
        described_class.new
      }.to raise_error(Remitmd::RemitError) { |e|
        expect(e.code).to eq(Remitmd::RemitError::SERVER_ERROR)
        expect(e.message).to include("not found")
      }
    end
  end

  # ── Address failures ────────────────────────────────────────────────────────

  describe "address command fails" do
    it "raises SERVER_ERROR when remit address returns non-zero" do
      stub_cli_address(address: "", stderr: "keystore locked", success: false)

      expect {
        described_class.new
      }.to raise_error(Remitmd::RemitError) { |e|
        expect(e.code).to eq(Remitmd::RemitError::SERVER_ERROR)
        expect(e.message).to include("failed to get address")
        expect(e.message).to include("keystore locked")
      }
    end

    it "raises SERVER_ERROR when address output is invalid" do
      stub_cli_address(address: "not-an-address")

      expect {
        described_class.new
      }.to raise_error(Remitmd::RemitError) { |e|
        expect(e.code).to eq(Remitmd::RemitError::SERVER_ERROR)
        expect(e.message).to include("invalid address")
      }
    end
  end

  # ── Sign failures ───────────────────────────────────────────────────────────

  describe "sign command fails" do
    before { stub_cli_address }

    it "raises SERVER_ERROR when remit sign returns non-zero" do
      stub_cli_sign(signature: "", stderr: "decryption failed", success: false)

      signer = described_class.new
      expect {
        signer.sign("\x00" * 32)
      }.to raise_error(Remitmd::RemitError) { |e|
        expect(e.code).to eq(Remitmd::RemitError::SERVER_ERROR)
        expect(e.message).to include("signing failed")
        expect(e.message).to include("decryption failed")
      }
    end

    it "raises SERVER_ERROR when signature output is invalid" do
      stub_cli_sign(signature: "0xshort")

      signer = described_class.new
      expect {
        signer.sign("\x00" * 32)
      }.to raise_error(Remitmd::RemitError) { |e|
        expect(e.code).to eq(Remitmd::RemitError::SERVER_ERROR)
        expect(e.message).to include("invalid signature")
      }
    end
  end

  # ── available? ──────────────────────────────────────────────────────────────

  describe ".available?" do
    let(:which_cmd) { Gem.win_platform? ? "where" : "which" }
    let(:meta_path) { File.join(Dir.home, ".remit", "keys", "default.meta") }
    let(:enc_path) { File.join(Dir.home, ".remit", "keys", "default.enc") }

    it "returns true when .meta file exists (keychain, no password)" do
      success = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(which_cmd, "remit").and_return(
        ["/usr/local/bin/remit\n", "", success]
      )
      allow(File).to receive(:exist?).with(meta_path).and_return(true)

      expect(described_class.available?).to be true
    end

    it "returns true when .enc file and password are set (no .meta)" do
      success = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(which_cmd, "remit").and_return(
        ["/usr/local/bin/remit\n", "", success]
      )
      allow(File).to receive(:exist?).with(meta_path).and_return(false)
      allow(File).to receive(:exist?).with(enc_path).and_return(true)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("REMIT_KEY_PASSWORD").and_return("secret")

      expect(described_class.available?).to be true
    end

    it "returns false when CLI is not on PATH" do
      failure = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).with(which_cmd, "remit").and_return(
        ["", "not found", failure]
      )

      expect(described_class.available?).to be false
    end

    it "returns false when no .meta and no .enc file" do
      success = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(which_cmd, "remit").and_return(
        ["/usr/local/bin/remit\n", "", success]
      )
      allow(File).to receive(:exist?).with(meta_path).and_return(false)
      allow(File).to receive(:exist?).with(enc_path).and_return(false)

      expect(described_class.available?).to be false
    end

    it "returns false when .enc exists but REMIT_KEY_PASSWORD is not set" do
      success = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(which_cmd, "remit").and_return(
        ["/usr/local/bin/remit\n", "", success]
      )
      allow(File).to receive(:exist?).with(meta_path).and_return(false)
      allow(File).to receive(:exist?).with(enc_path).and_return(true)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("REMIT_KEY_PASSWORD").and_return(nil)

      expect(described_class.available?).to be false
    end
  end

  # ── inspect / to_s ──────────────────────────────────────────────────────────

  describe "inspect / to_s" do
    before do
      stub_cli_address
    end

    it "includes address in inspect" do
      signer = described_class.new
      expect(signer.inspect).to include(MOCK_ADDRESS)
      expect(signer.inspect).to include("CliSigner")
    end

    it "inspect and to_s are identical" do
      signer = described_class.new
      expect(signer.to_s).to eq(signer.inspect)
    end
  end

  # ── Signer interface ────────────────────────────────────────────────────────

  describe "Signer interface" do
    before do
      stub_cli_address
    end

    it "includes the Signer module" do
      signer = described_class.new
      expect(signer).to be_a(Remitmd::Signer)
    end
  end

  # ── Custom cli_path ─────────────────────────────────────────────────────────

  describe "custom cli_path" do
    it "uses the provided cli_path" do
      status = instance_double(Process::Status, success?: true)
      expect(Open3).to receive(:capture3).with(
        "/opt/bin/remit", "address", stdin_data: ""
      ).and_return([MOCK_ADDRESS + "\n", "", status])

      described_class.new(cli_path: "/opt/bin/remit")
    end
  end
end
# rubocop:enable Metrics/BlockLength
