# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "uri"
require "json"
require "bigdecimal"

# Compliance tests: Ruby SDK against a real running server.
#
# Tests are skipped when the server is not reachable. Boot the server with:
#   docker compose -f docker-compose.compliance.yml up -d
#
# Environment variables:
#   REMIT_TEST_SERVER_URL  (default: http://localhost:3000)
#   REMIT_ROUTER_ADDRESS   (default: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8)

COMPLIANCE_SERVER_URL = ENV.fetch("REMIT_TEST_SERVER_URL", "http://localhost:3000")
COMPLIANCE_ROUTER_ADDR = ENV.fetch("REMIT_ROUTER_ADDRESS", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8")

module ComplianceHelpers
  def server_available?
    uri = URI.parse("#{COMPLIANCE_SERVER_URL}/health")
    resp = Net::HTTP.get_response(uri)
    resp.code.to_i == 200
  rescue StandardError
    false
  end

  def http_post(path, body, token: nil)
    uri = URI.parse("#{COMPLIANCE_SERVER_URL}#{path}")
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req["Authorization"] = "Bearer #{token}" if token
    req.body = body.to_json
    Net::HTTP.start(uri.hostname, uri.port) { |h| h.request(req) }
  end

  def http_get(path, token: nil)
    uri = URI.parse("#{COMPLIANCE_SERVER_URL}#{path}")
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{token}" if token
    Net::HTTP.start(uri.hostname, uri.port) { |h| h.request(req) }
  end

  def register_and_get_key
    email = "compliance.ruby.#{(Time.now.to_f * 1000).to_i}@test.remitmd.local"
    reg_resp = http_post("/api/v0/auth/register",
      { "email" => email, "password" => "ComplianceTestPass1!" })
    reg = JSON.parse(reg_resp.body)
    token       = reg["token"] || raise("register failed: #{reg_resp.body}")
    wallet_addr = reg["wallet_address"] || raise("no wallet_address")

    key_resp  = http_get("/api/v0/auth/agent-key", token: token)
    key_data  = JSON.parse(key_resp.body)
    private_key = key_data["private_key"] || raise("agent-key failed: #{key_resp.body}")

    [private_key, wallet_addr]
  end

  def fund_wallet(wallet_addr)
    faucet_resp = http_post("/api/v0/faucet", { "wallet" => wallet_addr, "amount" => 1000 })
    data = JSON.parse(faucet_resp.body)
    raise "faucet failed: #{faucet_resp.body}" unless data["tx_hash"]
  end

  def make_wallet(private_key)
    Remitmd::RemitWallet.new(
      private_key:    private_key,
      chain:          "base_sepolia",
      api_url:        COMPLIANCE_SERVER_URL,
      router_address: COMPLIANCE_ROUTER_ADDR
    )
  end

  def funded_wallet_pair
    # Payer: registered + funded via faucet (1000 USDC).
    payer_pk, payer_addr = register_and_get_key
    fund_wallet(payer_addr)
    payer = make_wallet(payer_pk)
    # Payee: registered only.
    _payee_pk, payee_addr = register_and_get_key
    [payer, payee_addr]
  end
end

RSpec.describe "Ruby SDK compliance" do
  include ComplianceHelpers

  before(:each) do
    skip "Compliance server not reachable at #{COMPLIANCE_SERVER_URL}" unless server_available?
  end

  # ─── Auth ───────────────────────────────────────────────────────────────────

  describe "authentication" do
    it "authenticated request returns balance, not 401" do
      pk, _addr = register_and_get_key
      wallet = make_wallet(pk)
      bal = wallet.balance
      expect(bal).not_to be_nil
    end

    it "unauthenticated POST /payments/direct returns 401" do
      resp = http_post("/api/v0/payments/direct",
        { "to" => "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", "amount" => "1.000000" })
      expect(resp.code.to_i).to eq(401)
    end
  end

  # ─── Payments ───────────────────────────────────────────────────────────────

  describe "pay_direct" do
    it "returns a non-empty tx_hash on success" do
      payer, payee_addr = funded_wallet_pair
      tx = payer.pay(payee_addr, BigDecimal("5.0"), memo: "ruby compliance test")
      expect(tx.tx_hash).not_to be_nil
      expect(tx.tx_hash).not_to be_empty
    end

    it "raises RemitError when amount is below minimum" do
      payer, payee_addr = funded_wallet_pair
      expect do
        payer.pay(payee_addr, BigDecimal("0.0001"))
      end.to raise_error(Remitmd::RemitError)
    end
  end
end
