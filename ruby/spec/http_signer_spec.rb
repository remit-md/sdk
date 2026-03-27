# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "webrick"

# rubocop:disable Metrics/BlockLength
RSpec.describe Remitmd::HttpSigner do
  MOCK_ADDRESS   = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  MOCK_SIGNATURE = "0x#{"ab" * 32}#{"cd" * 32}1b"
  VALID_TOKEN    = "rmit_sk_#{"a1" * 32}"

  # ── Mock signer server helpers ──────────────────────────────────────────────

  # Start a WEBrick server on a random port with configurable route overrides.
  # Returns [server, url]. Caller must call server.shutdown in an after block.
  def start_mock_server(overrides: {})
    null_logger = WEBrick::Log.new(StringIO.new, WEBrick::Log::FATAL)
    server = WEBrick::HTTPServer.new(
      Port: 0,
      Logger: null_logger,
      AccessLog: []
    )

    server.mount_proc "/health" do |_req, res|
      res.content_type = "application/json"
      res.body = '{"ok":true}'
    end

    server.mount_proc "/address" do |req, res|
      if overrides.key?("/address")
        status, body = overrides["/address"]
        res.status = status
        res.content_type = "application/json"
        res.body = body.is_a?(String) ? body : body.to_json
        next
      end

      auth = req["Authorization"] || ""
      unless auth == "Bearer #{VALID_TOKEN}"
        res.status = 401
        res.content_type = "application/json"
        res.body = '{"error":"unauthorized"}'
        next
      end

      res.content_type = "application/json"
      res.body = { address: MOCK_ADDRESS }.to_json
    end

    server.mount_proc "/sign/digest" do |req, res|
      if overrides.key?("/sign/digest")
        status, body = overrides["/sign/digest"]
        res.status = status
        res.content_type = "application/json"
        res.body = body.is_a?(String) ? body : body.to_json
        next
      end

      auth = req["Authorization"] || ""
      unless auth == "Bearer #{VALID_TOKEN}"
        res.status = 401
        res.content_type = "application/json"
        res.body = '{"error":"unauthorized"}'
        next
      end

      res.content_type = "application/json"
      res.body = { signature: MOCK_SIGNATURE }.to_json
    end

    port = server.config[:Port]
    thread = Thread.new { server.start }
    # Wait until server is listening
    sleep 0.05 until thread.alive?

    [server, "http://127.0.0.1:#{port}"]
  end

  # ── Happy path ──────────────────────────────────────────────────────────────

  describe "happy path" do
    let(:server_and_url) { start_mock_server }
    let(:server)         { server_and_url[0] }
    let(:url)            { server_and_url[1] }

    after { server.shutdown }

    it "fetches and caches the address on construction" do
      signer = described_class.new(url: url, token: VALID_TOKEN)
      expect(signer.address).to eq(MOCK_ADDRESS)
    end

    it "signs a digest and returns the signature" do
      signer = described_class.new(url: url, token: VALID_TOKEN)
      digest = "\x00" * 32
      sig = signer.sign(digest)
      expect(sig).to eq(MOCK_SIGNATURE)
    end
  end

  # ── Server unreachable ──────────────────────────────────────────────────────

  describe "server unreachable" do
    it "raises NETWORK_ERROR when server is unreachable" do
      expect {
        described_class.new(url: "http://127.0.0.1:1", token: VALID_TOKEN)
      }.to raise_error(Remitmd::RemitError) { |e|
        expect(e.code).to eq(Remitmd::RemitError::NETWORK_ERROR)
        expect(e.message).to include("cannot reach")
      }
    end
  end

  # ── 401 Unauthorized ────────────────────────────────────────────────────────

  describe "401 on GET /address" do
    let(:server_and_url) { start_mock_server }
    let(:server)         { server_and_url[0] }
    let(:url)            { server_and_url[1] }

    after { server.shutdown }

    it "raises UNAUTHORIZED with auth hint on bad token" do
      expect {
        described_class.new(url: url, token: "bad_token")
      }.to raise_error(Remitmd::RemitError) { |e|
        expect(e.code).to eq(Remitmd::RemitError::UNAUTHORIZED)
        expect(e.message).to include("unauthorized")
      }
    end
  end

  describe "401 on POST /sign/digest" do
    it "raises UNAUTHORIZED when sign returns 401" do
      srv, url = start_mock_server(
        overrides: { "/sign/digest" => [401, { error: "unauthorized" }] }
      )
      begin
        signer = described_class.new(url: url, token: VALID_TOKEN)
        expect {
          signer.sign("\x00" * 32)
        }.to raise_error(Remitmd::RemitError) { |e|
          expect(e.code).to eq(Remitmd::RemitError::UNAUTHORIZED)
          expect(e.message).to include("unauthorized")
        }
      ensure
        srv.shutdown
      end
    end
  end

  # ── 403 Policy denied ──────────────────────────────────────────────────────

  describe "403 policy denied" do
    let(:server_and_url) do
      start_mock_server(
        overrides: {
          "/sign/digest" => [403, { error: "policy_denied", reason: "chain not allowed" }]
        }
      )
    end
    let(:server) { server_and_url[0] }
    let(:url)    { server_and_url[1] }

    after { server.shutdown }

    it "raises with the policy reason from the response" do
      signer = described_class.new(url: url, token: VALID_TOKEN)
      expect {
        signer.sign("\x00" * 32)
      }.to raise_error(Remitmd::RemitError) { |e|
        expect(e.code).to eq(Remitmd::RemitError::UNAUTHORIZED)
        expect(e.message).to include("policy denied")
        expect(e.message).to include("chain not allowed")
      }
    end
  end

  # ── 500 Server error ────────────────────────────────────────────────────────

  describe "500 server error" do
    let(:server_and_url) do
      start_mock_server(
        overrides: {
          "/sign/digest" => [500, { error: "internal_error" }]
        }
      )
    end
    let(:server) { server_and_url[0] }
    let(:url)    { server_and_url[1] }

    after { server.shutdown }

    it "raises SERVER_ERROR with status code" do
      signer = described_class.new(url: url, token: VALID_TOKEN)
      expect {
        signer.sign("\x00" * 32)
      }.to raise_error(Remitmd::RemitError) { |e|
        expect(e.code).to eq(Remitmd::RemitError::SERVER_ERROR)
        expect(e.message).to include("500")
      }
    end
  end

  # ── Malformed response ──────────────────────────────────────────────────────

  describe "malformed response" do
    let(:server_and_url) do
      start_mock_server(
        overrides: {
          "/sign/digest" => [200, { not_signature: true }]
        }
      )
    end
    let(:server) { server_and_url[0] }
    let(:url)    { server_and_url[1] }

    after { server.shutdown }

    it "raises SERVER_ERROR when no signature field in response" do
      signer = described_class.new(url: url, token: VALID_TOKEN)
      expect {
        signer.sign("\x00" * 32)
      }.to raise_error(Remitmd::RemitError) { |e|
        expect(e.code).to eq(Remitmd::RemitError::SERVER_ERROR)
        expect(e.message).to include("no signature")
      }
    end
  end

  describe "malformed JSON from GET /address" do
    let(:server_and_url) do
      start_mock_server(
        overrides: {
          "/address" => [200, "not valid json {{{"]
        }
      )
    end
    let(:server) { server_and_url[0] }
    let(:url)    { server_and_url[1] }

    after { server.shutdown }

    it "raises SERVER_ERROR on malformed JSON" do
      expect {
        described_class.new(url: url, token: VALID_TOKEN)
      }.to raise_error(Remitmd::RemitError) { |e|
        expect(e.code).to eq(Remitmd::RemitError::SERVER_ERROR)
        expect(e.message).to include("malformed JSON")
      }
    end
  end

  # ── Token not leaked ────────────────────────────────────────────────────────

  describe "token not leaked" do
    let(:server_and_url) { start_mock_server }
    let(:server)         { server_and_url[0] }
    let(:url)            { server_and_url[1] }

    after { server.shutdown }

    it "does not include the token in inspect" do
      signer = described_class.new(url: url, token: VALID_TOKEN)
      expect(signer.inspect).not_to include(VALID_TOKEN)
      expect(signer.inspect).to include(MOCK_ADDRESS)
    end

    it "does not include the token in to_s" do
      signer = described_class.new(url: url, token: VALID_TOKEN)
      expect(signer.to_s).not_to include(VALID_TOKEN)
      expect(signer.to_s).to include(MOCK_ADDRESS)
    end
  end
end
# rubocop:enable Metrics/BlockLength
