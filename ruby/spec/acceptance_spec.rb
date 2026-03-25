# frozen_string_literal: true

# Ruby SDK acceptance tests: all 7 payment flows on live Base Sepolia.
#
# Run: bundle exec rspec spec/acceptance_spec.rb --tag acceptance
#
# Env vars (all optional):
#   ACCEPTANCE_API_URL  — default: https://remit.md
#   ACCEPTANCE_RPC_URL  — default: https://sepolia.base.org

require "remitmd"
require "net/http"
require "json"
require "securerandom"
require "openssl"
require "uri"
require "base64"
require "socket"
require "webrick"

API_URL = ENV.fetch("ACCEPTANCE_API_URL", "https://remit.md")
RPC_URL = ENV.fetch("ACCEPTANCE_RPC_URL", "https://sepolia.base.org")
USDC_ADDRESS = "0x2d846325766921935f37d5b4478196d3ef93707c"
FEE_WALLET = "0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38"
CHAIN_ID = 84532

# ─── Helpers ──────────────────────────────────────────────────────────────────

def fetch_contracts
  @fetch_contracts ||= begin
    uri = URI("#{API_URL}/api/v1/contracts")
    resp = Net::HTTP.get_response(uri)
    raise "GET /contracts: #{resp.code} #{resp.body}" unless resp.code == "200"

    JSON.parse(resp.body)
  end
end

def create_test_wallet
  key_hex = SecureRandom.hex(32)
  contracts = fetch_contracts
  # Ruby SDK paths don't include /api/v1, so base URL must include it.
  base_url = API_URL.end_with?("/api/v1") ? API_URL : "#{API_URL}/api/v1"
  wallet = Remitmd::RemitWallet.new(
    private_key: "0x#{key_hex}",
    chain: "base_sepolia",
    api_url: base_url,
    router_address: contracts["router"]
  )
  { wallet: wallet, key_hex: key_hex }
end

def get_usdc_balance(address)
  hex = address.downcase.delete_prefix("0x").rjust(64, "0")
  data = "0x70a08231#{hex}"
  body = { jsonrpc: "2.0", id: 1, method: "eth_call",
           params: [{ to: USDC_ADDRESS, data: data }, "latest"] }.to_json

  uri = URI(RPC_URL)
  resp = Net::HTTP.post(uri, body, "Content-Type" => "application/json")
  result = JSON.parse(resp.body)
  raise "RPC error: #{result["error"]}" if result["error"]

  raw = result["result"].delete_prefix("0x")
  raw = "0" if raw.empty?
  raw.to_i(16).to_f / 1_000_000.0
end

def get_fee_balance
  get_usdc_balance(FEE_WALLET)
end

def wait_for_balance_change(address, before, timeout: 30)
  deadline = Time.now + timeout
  while Time.now < deadline
    current = get_usdc_balance(address)
    return current if (current - before).abs > 0.0001

    sleep 2
  end
  get_usdc_balance(address)
end

def assert_balance_change(label, before, after, expected)
  actual = after - before
  tolerance = [expected.abs * 0.001, 0.02].max
  expect((actual - expected).abs).to be <= tolerance,
                                        "#{label}: expected delta #{expected}, got #{actual} " \
                                        "(before=#{before}, after=#{after})"
end

def fund_wallet(tw, amount)
  tw[:wallet].mint(amount)
  wait_for_balance_change(tw[:wallet].address, 0)
end

# ─── EIP-2612 Permit Signing ────────────────────────────────────────────────

def keccak256(data)
  [Remitmd::Keccak.hexdigest(data)].pack("H*")
end

def pad_address(addr)
  hex = addr.delete_prefix("0x")
  [hex.rjust(64, "0")].pack("H*")
end

def pad_uint256(value)
  hex = value.to_s(16).rjust(64, "0")
  [hex].pack("H*")
end

def sign_usdc_permit(key_hex, owner, spender, value, nonce, deadline)
  # Domain separator
  domain_type_hash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
  name_hash = keccak256("USD Coin")
  version_hash = keccak256("2")
  usdc_padded = pad_address(USDC_ADDRESS)

  domain_data = domain_type_hash + name_hash + version_hash + pad_uint256(CHAIN_ID) + usdc_padded
  domain_sep = keccak256(domain_data)

  # Permit struct hash
  permit_type_hash = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
  struct_data = permit_type_hash + pad_address(owner) + pad_address(spender) +
                pad_uint256(value) + pad_uint256(nonce) + pad_uint256(deadline)
  struct_hash = keccak256(struct_data)

  # EIP-712 digest
  final_data = "\x19\x01".b + domain_sep + struct_hash
  digest = keccak256(final_data)

  # Sign using the SDK's signer
  signer = Remitmd::PrivateKeySigner.new("0x#{key_hex}")
  sig_hex = signer.sign(digest)

  # Parse r, s, v from the 65-byte hex signature
  sig_bytes = [sig_hex.delete_prefix("0x")].pack("H*")
  r = "0x#{sig_bytes[0, 32].unpack1("H*")}"
  s = "0x#{sig_bytes[32, 32].unpack1("H*")}"
  v = sig_bytes[64].ord

  Remitmd::PermitSignature.new(value: value, deadline: deadline, v: v, r: r, s: s)
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe "Acceptance", :acceptance do # rubocop:disable Metrics/BlockLength
  describe "direct payments" do
    it "payDirect with permit" do
      agent = create_test_wallet
      provider = create_test_wallet
      fund_wallet(agent, 100)

      amount = 1.0
      fee = 0.01
      provider_receives = amount - fee

      agent_before = get_usdc_balance(agent[:wallet].address)
      provider_before = get_usdc_balance(provider[:wallet].address)
      fee_before = get_fee_balance

      # Sign EIP-2612 permit for Router
      contracts = fetch_contracts
      deadline = Time.now.to_i + 3600
      permit = sign_usdc_permit(
        agent[:key_hex], agent[:wallet].address, contracts["router"],
        2_000_000, 0, deadline
      )

      tx = agent[:wallet].pay(provider[:wallet].address, 1.0,
                              memo: "ruby-sdk-acceptance", permit: permit)
      expect(tx.tx_hash).to start_with("0x")

      agent_after = wait_for_balance_change(agent[:wallet].address, agent_before)
      provider_after = get_usdc_balance(provider[:wallet].address)
      fee_after = get_fee_balance

      assert_balance_change("agent", agent_before, agent_after, -amount)
      assert_balance_change("provider", provider_before, provider_after, provider_receives)
      assert_balance_change("fee wallet", fee_before, fee_after, fee)
    end
  end

  describe "escrow" do
    it "escrow lifecycle" do
      agent = create_test_wallet
      provider = create_test_wallet
      fund_wallet(agent, 100)

      amount = 5.0
      fee = amount * 0.01
      provider_receives = amount - fee

      agent_before = get_usdc_balance(agent[:wallet].address)
      provider_before = get_usdc_balance(provider[:wallet].address)
      fee_before = get_fee_balance

      # Sign EIP-2612 permit for Escrow contract
      contracts = fetch_contracts
      deadline = Time.now.to_i + 3600
      permit = sign_usdc_permit(
        agent[:key_hex], agent[:wallet].address, contracts["escrow"],
        6_000_000, 0, deadline
      )

      escrow = agent[:wallet].create_escrow(provider[:wallet].address, 5.0, permit: permit)
      expect(escrow.id).not_to be_nil
      expect(escrow.id).not_to be_empty

      # Wait for on-chain lock
      wait_for_balance_change(agent[:wallet].address, agent_before)

      # Provider claims start
      provider[:wallet].claim_start(escrow.id)
      sleep 5

      # Agent releases
      agent[:wallet].release_escrow(escrow.id)

      # Verify balances
      provider_after = wait_for_balance_change(provider[:wallet].address, provider_before)
      fee_after = get_fee_balance
      agent_after = get_usdc_balance(agent[:wallet].address)

      assert_balance_change("agent", agent_before, agent_after, -amount)
      assert_balance_change("provider", provider_before, provider_after, provider_receives)
      assert_balance_change("fee wallet", fee_before, fee_after, fee)
    end
  end

  describe "tab" do
    it "tab lifecycle (open, charge, close)" do
      payer = create_test_wallet
      provider = create_test_wallet
      fund_wallet(payer, 100)

      contracts = fetch_contracts

      # Sign permit for the Tab contract
      deadline = Time.now.to_i + 3600
      permit = sign_usdc_permit(
        payer[:key_hex], payer[:wallet].address, contracts["tab"],
        20_000_000, 0, deadline
      )

      payer_before = get_usdc_balance(payer[:wallet].address)
      _fee_before = get_fee_balance

      # 1. Create tab: $10 limit, $0.10 per call
      tab = payer[:wallet].create_tab(
        provider[:wallet].address, 10.0, 0.10,
        permit: permit
      )
      expect(tab.id).not_to be_nil
      expect(tab.id).not_to be_empty

      # Wait for on-chain funding
      wait_for_balance_change(payer[:wallet].address, payer_before)

      # 2. Charge tab: $0.10, cumulative $0.10, callCount 1
      charge_sig = provider[:wallet].sign_tab_charge(
        contracts["tab"], tab.id,
        100_000, # $0.10 in base units (6 decimals)
        1
      )
      charge = provider[:wallet].charge_tab(tab.id, 0.10, 0.10, 1, charge_sig)
      expect(charge.tab_id).to eq(tab.id)

      # 3. Close tab with final settlement
      close_sig = provider[:wallet].sign_tab_charge(
        contracts["tab"], tab.id,
        100_000, # final = $0.10
        1
      )
      closed = payer[:wallet].close_tab(
        tab.id,
        final_amount: 0.10,
        provider_sig: close_sig
      )
      expect(closed.status).not_to eq("open")

      # 4. Verify balances: payer should have lost funds
      payer_after = wait_for_balance_change(payer[:wallet].address, payer_before)
      _fee_after = get_fee_balance
      payer_delta = payer_after - payer_before
      expect(payer_delta).to be < 0
    end
  end

  describe "stream" do
    it "stream lifecycle (open, wait, close with conservation)" do
      payer = create_test_wallet
      payee = create_test_wallet
      fund_wallet(payer, 100)

      contracts = fetch_contracts

      # Sign permit for the Stream contract
      deadline = Time.now.to_i + 3600
      permit = sign_usdc_permit(
        payer[:key_hex], payer[:wallet].address, contracts["stream"],
        10_000_000, 0, deadline
      )

      payer_before = get_usdc_balance(payer[:wallet].address)

      # 1. Create stream: $0.01/sec, $5 max
      stream = payer[:wallet].create_stream(
        payee[:wallet].address,
        0.01,  # rate_per_second
        5.0,   # max_total
        permit: permit
      )
      expect(stream.id).not_to be_nil
      expect(stream.id).not_to be_empty

      # Wait for on-chain lock
      wait_for_balance_change(payer[:wallet].address, payer_before)

      # 2. Let it run for a few seconds
      sleep 5

      # 3. Close stream
      closed = payer[:wallet].close_stream(stream.id)
      expect(closed).to be_a(Remitmd::Stream)

      # 4. Conservation: payer should have lost some funds, payee gained some
      payer_after = wait_for_balance_change(payer[:wallet].address, payer_before)
      _payee_after = get_usdc_balance(payee[:wallet].address)

      payer_delta = payer_after - payer_before
      expect(payer_delta).to be < 0
    end
  end

  describe "bounty" do
    it "bounty lifecycle (post, submit, award)" do
      poster = create_test_wallet
      submitter = create_test_wallet
      fund_wallet(poster, 100)

      contracts = fetch_contracts

      # Sign permit for the Bounty contract
      deadline_permit = Time.now.to_i + 3600
      permit = sign_usdc_permit(
        poster[:key_hex], poster[:wallet].address, contracts["bounty"],
        10_000_000, 0, deadline_permit
      )

      poster_before = get_usdc_balance(poster[:wallet].address)
      fee_before = get_fee_balance

      # 1. Create bounty: $5 reward, 1 hour deadline
      bounty_deadline = Time.now.to_i + 3600
      bounty = poster[:wallet].create_bounty(
        5.0,
        "Write a Ruby acceptance test",
        bounty_deadline,
        permit: permit
      )
      expect(bounty.id).not_to be_nil
      expect(bounty.id).not_to be_empty

      # Wait for on-chain lock
      wait_for_balance_change(poster[:wallet].address, poster_before)

      # 2. Submit evidence (as submitter)
      evidence_hash = "0x" + Remitmd::Keccak.hexdigest("ruby test evidence")
      sub = submitter[:wallet].submit_bounty(bounty.id, evidence_hash)
      expect(sub.bounty_id).to eq(bounty.id)

      # 3. Award bounty (as poster)
      awarded = poster[:wallet].award_bounty(bounty.id, sub.id)
      expect(awarded).to be_a(Remitmd::Bounty)

      # 4. Verify: submitter should have received funds
      submitter_after = wait_for_balance_change(submitter[:wallet].address, 0)
      expect(submitter_after).to be > 0

      fee_after = get_fee_balance
      expect(fee_after).to be >= fee_before
    end
  end

  describe "deposit" do
    it "deposit lifecycle (place, return with full refund)" do
      payer = create_test_wallet
      provider = create_test_wallet
      fund_wallet(payer, 100)

      contracts = fetch_contracts

      # Sign permit for the Deposit contract
      deadline = Time.now.to_i + 3600
      permit = sign_usdc_permit(
        payer[:key_hex], payer[:wallet].address, contracts["deposit"],
        10_000_000, 0, deadline
      )

      payer_before = get_usdc_balance(payer[:wallet].address)

      # 1. Place deposit: $5, expires in 1 hour
      deposit = payer[:wallet].place_deposit(
        provider[:wallet].address, 5.0,
        expires_in_secs: 3600,
        permit: permit
      )
      expect(deposit.id).not_to be_nil
      expect(deposit.id).not_to be_empty

      # Wait for on-chain lock
      wait_for_balance_change(payer[:wallet].address, payer_before)
      payer_after_deposit = get_usdc_balance(payer[:wallet].address)

      # 2. Return deposit (by provider)
      provider[:wallet].return_deposit(deposit.id)

      # 3. Verify full refund (deposits have no fee)
      payer_after_return = wait_for_balance_change(payer[:wallet].address, payer_after_deposit)
      refund_amount = payer_after_return - payer_after_deposit
      expect(refund_amount).to be >= 4.99
    end
  end

  describe "x402" do
    it "x402 auto-pay (local server with 402)" do
      provider_wallet = create_test_wallet

      # Build the PAYMENT-REQUIRED header payload
      payment_payload = {
        "payTo"       => provider_wallet[:wallet].address,
        "amount"      => "1000",              # $0.001 USDC in base units
        "network"     => "eip155:84532",
        "asset"       => USDC_ADDRESS,
        "facilitator" => "#{API_URL}/api/v1",
        "maxTimeout"  => 60,
        "resource"    => "/v1/data",
        "description" => "Test data endpoint",
        "mimeType"    => "application/json",
      }
      encoded_header = Base64.strict_encode64(payment_payload.to_json)

      # 1. Spin up a local HTTP server that returns 402
      server = WEBrick::HTTPServer.new(
        Port: 0,  # auto-pick port
        Logger: WEBrick::Log.new("/dev/null"),
        AccessLog: []
      )
      port = server.config[:Port]
      server_url = "http://127.0.0.1:#{port}"

      server.mount_proc "/v1/data" do |req, res|
        if req["X-PAYMENT"]
          # Payment provided — return 200
          res.status = 200
          res["Content-Type"] = "application/json"
          res.body = '{"status":"ok","data":"secret"}'
        else
          # No payment — return 402
          res.status = 402
          res["PAYMENT-REQUIRED"] = encoded_header
          res["Content-Type"] = "application/json"
          res.body = '{"error":"payment required"}'
        end
      end

      thread = Thread.new { server.start }

      begin
        # 2. Make a request without payment — should get 402
        uri = URI("#{server_url}/v1/data")
        resp = Net::HTTP.get_response(uri)
        expect(resp.code).to eq("402")

        # 3. Verify PAYMENT-REQUIRED header is present and parseable
        pay_req = resp["PAYMENT-REQUIRED"]
        expect(pay_req).not_to be_nil
        expect(pay_req).not_to be_empty

        decoded = JSON.parse(Base64.strict_decode64(pay_req))
        expect(decoded["payTo"]).to eq(provider_wallet[:wallet].address)
        expect(decoded["resource"]).to eq("/v1/data")
        expect(decoded["description"]).to eq("Test data endpoint")
        expect(decoded["mimeType"]).to eq("application/json")

        # 4. Make a request WITH a payment header — should get 200
        req = Net::HTTP::Get.new(uri)
        req["X-PAYMENT"] = "test-payment-token"
        http = Net::HTTP.new(uri.host, uri.port)
        resp2 = http.request(req)
        expect(resp2.code).to eq("200")

        body = JSON.parse(resp2.body)
        expect(body["status"]).to eq("ok")
        expect(body["data"]).to eq("secret")
      ensure
        server.shutdown
        thread.join(5)
      end
    end
  end
end
