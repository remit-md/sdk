# frozen_string_literal: true

# Ruby SDK acceptance tests: all 9 payment flows with 2 shared wallets.
#
# Creates agent (payer) + provider (payee) wallets once, mints 100 USDC
# to agent, then runs all 9 flows sequentially with small amounts.
#
# Flows: direct, escrow, tab, stream, bounty, deposit, x402_prepare,
#        ap2_discovery, ap2_payment.
#
# Run: bundle exec rspec spec/acceptance_spec.rb --tag acceptance
#
# Env vars (all optional):
#   ACCEPTANCE_API_URL  - default: https://testnet.remit.md
#   ACCEPTANCE_RPC_URL  - default: https://sepolia.base.org

require "remitmd"
require "net/http"
require "json"
require "securerandom"
require "uri"
require "base64"

API_URL = ENV.fetch("ACCEPTANCE_API_URL", "https://testnet.remit.md")
RPC_URL = ENV.fetch("ACCEPTANCE_RPC_URL", "https://sepolia.base.org")

# ─── Helpers ──────────────────────────────────────────────────────────────────

def log_tx(flow, step, tx_hash)
  puts "[ACCEPTANCE] #{flow} | #{step} | tx=#{tx_hash} | https://sepolia.basescan.org/tx/#{tx_hash}"
end

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
  base_url = API_URL.end_with?("/api/v1") ? API_URL : "#{API_URL}/api/v1"
  wallet = Remitmd::RemitWallet.new(
    private_key: "0x#{key_hex}",
    chain: "base_sepolia",
    api_url: base_url,
    router_address: contracts["router"]
  )
  puts "[ACCEPTANCE] wallet: #{wallet.address} (chain=84532)"
  { wallet: wallet, key_hex: key_hex }
end

def get_usdc_balance(address, usdc_address: nil)
  usdc_address ||= fetch_contracts["usdc"]
  hex = address.downcase.delete_prefix("0x").rjust(64, "0")
  data = "0x70a08231#{hex}"
  body = { jsonrpc: "2.0", id: 1, method: "eth_call",
           params: [{ to: usdc_address, data: data }, "latest"] }.to_json

  uri = URI(RPC_URL)
  resp = Net::HTTP.post(uri, body, "Content-Type" => "application/json")
  result = JSON.parse(resp.body)
  raise "RPC error: #{result["error"]}" if result["error"]

  raw = result["result"].delete_prefix("0x")
  raw = "0" if raw.empty?
  raw.to_i(16).to_f / 1_000_000.0
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
  puts "[ACCEPTANCE] mint: #{amount} USDC -> #{tw[:wallet].address}"
  result = tw[:wallet].mint(amount)
  log_tx("mint", "mint", result["tx_hash"]) if result.is_a?(Hash) && result["tx_hash"]
  wait_for_balance_change(tw[:wallet].address, 0)
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe "Acceptance: all 9 flows", :acceptance, order: :defined do # rubocop:disable Metrics/BlockLength
  before(:all) do
    @agent = create_test_wallet
    @provider = create_test_wallet
    fund_wallet(@agent, 100)
  end

  # ── Flow 1: Direct ──────────────────────────────────────────────────────────

  it "01 direct payment with permit" do
    amount = 1.0

    agent_before = get_usdc_balance(@agent[:wallet].address)
    provider_before = get_usdc_balance(@provider[:wallet].address)

    permit = @agent[:wallet].sign_permit("direct", amount)
    tx = @agent[:wallet].pay(@provider[:wallet].address, amount,
                             memo: "acceptance-direct", permit: permit)

    expect(tx.tx_hash).to start_with("0x")
    log_tx("direct", "#{amount} USDC #{@agent[:wallet].address}->#{@provider[:wallet].address}", tx.tx_hash)

    agent_after = wait_for_balance_change(@agent[:wallet].address, agent_before)
    provider_after = get_usdc_balance(@provider[:wallet].address)

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change("provider", provider_before, provider_after, amount * 0.99)
  end

  # ── Flow 2: Escrow ─────────────────────────────────────────────────────────

  it "02 escrow lifecycle" do
    amount = 2.0

    agent_before = get_usdc_balance(@agent[:wallet].address)
    provider_before = get_usdc_balance(@provider[:wallet].address)

    permit = @agent[:wallet].sign_permit("escrow", amount)
    escrow = @agent[:wallet].create_escrow(@provider[:wallet].address, amount, permit: permit)
    expect(escrow.id).not_to be_nil
    expect(escrow.id).not_to be_empty
    puts "[ACCEPTANCE] escrow | fund #{amount} USDC | id=#{escrow.id}"

    wait_for_balance_change(@agent[:wallet].address, agent_before)

    @provider[:wallet].claim_start(escrow.id)
    puts "[ACCEPTANCE] escrow | claim_start"
    sleep 5

    release = @agent[:wallet].release_escrow(escrow.id)
    log_tx("escrow", "release", release.tx_hash) if release.tx_hash

    provider_after = wait_for_balance_change(@provider[:wallet].address, provider_before)
    agent_after = get_usdc_balance(@agent[:wallet].address)

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change("provider", provider_before, provider_after, amount * 0.99)
  end

  # ── Flow 3: Tab ────────────────────────────────────────────────────────────

  it "03 tab lifecycle (open, charge, close)" do
    limit = 5.0
    charge_amount = 1.0
    charge_units = (charge_amount * 1_000_000).to_i

    agent_before = get_usdc_balance(@agent[:wallet].address)
    provider_before = get_usdc_balance(@provider[:wallet].address)

    contracts = fetch_contracts
    tab_contract = contracts["tab"]

    permit = @agent[:wallet].sign_permit("tab", limit)
    tab = @agent[:wallet].create_tab(
      @provider[:wallet].address, limit, 0.1,
      permit: permit
    )
    expect(tab.id).not_to be_nil
    expect(tab.id).not_to be_empty
    log_tx("tab", "open limit=#{limit}", tab.tx_hash) if tab.respond_to?(:tx_hash) && tab.tx_hash

    wait_for_balance_change(@agent[:wallet].address, agent_before)

    call_count = 1
    charge_sig = @provider[:wallet].sign_tab_charge(
      tab_contract, tab.id,
      charge_units,
      call_count
    )
    charge = @provider[:wallet].charge_tab(tab.id, charge_amount, charge_amount, call_count, charge_sig)
    expect(charge.tab_id).to eq(tab.id)
    puts "[ACCEPTANCE] tab | charge #{charge_amount} USDC"

    close_sig = @provider[:wallet].sign_tab_charge(
      tab_contract, tab.id,
      charge_units,
      call_count
    )
    closed = @agent[:wallet].close_tab(
      tab.id,
      final_amount: charge_amount,
      provider_sig: close_sig
    )
    puts "[ACCEPTANCE] tab | close"

    provider_after = wait_for_balance_change(@provider[:wallet].address, provider_before)
    agent_after = get_usdc_balance(@agent[:wallet].address)

    assert_balance_change("agent", agent_before, agent_after, -charge_amount)
    assert_balance_change("provider", provider_before, provider_after, charge_amount * 0.99)
  end

  # ── Flow 4: Stream ─────────────────────────────────────────────────────────

  it "04 stream lifecycle (open, wait, close)" do
    rate = 0.1 # $0.10/s
    max_total = 2.0

    agent_before = get_usdc_balance(@agent[:wallet].address)
    provider_before = get_usdc_balance(@provider[:wallet].address)

    permit = @agent[:wallet].sign_permit("stream", max_total)
    stream = @agent[:wallet].create_stream(
      @provider[:wallet].address,
      rate,
      max_total,
      permit: permit
    )
    expect(stream.id).not_to be_nil
    expect(stream.id).not_to be_empty
    log_tx("stream", "open rate=#{rate}/s max=#{max_total}", stream.tx_hash) if stream.respond_to?(:tx_hash) && stream.tx_hash

    wait_for_balance_change(@agent[:wallet].address, agent_before)
    sleep 5

    closed = @agent[:wallet].close_stream(stream.id)
    expect(closed).to be_a(Remitmd::Stream)
    puts "[ACCEPTANCE] stream | close | status=#{closed.status}"

    provider_after = wait_for_balance_change(@provider[:wallet].address, provider_before)
    agent_after = get_usdc_balance(@agent[:wallet].address)

    agent_loss = agent_before - agent_after
    expect(agent_loss).to be > 0.05, "agent should lose money, loss=#{agent_loss}"
    expect(agent_loss).to be <= max_total + 0.01

    provider_gain = provider_after - provider_before
    expect(provider_gain).to be > 0.04, "provider should gain, gain=#{provider_gain}"
  end

  # ── Flow 5: Bounty ─────────────────────────────────────────────────────────

  it "05 bounty lifecycle (post, submit, award)" do
    amount = 2.0
    deadline_ts = Time.now.to_i + 3600

    agent_before = get_usdc_balance(@agent[:wallet].address)
    provider_before = get_usdc_balance(@provider[:wallet].address)

    permit = @agent[:wallet].sign_permit("bounty", amount)
    bounty = @agent[:wallet].create_bounty(
      amount,
      "acceptance-bounty",
      deadline_ts,
      permit: permit
    )
    expect(bounty.id).not_to be_nil
    expect(bounty.id).not_to be_empty
    log_tx("bounty", "post #{amount} USDC", bounty.tx_hash) if bounty.respond_to?(:tx_hash) && bounty.tx_hash

    wait_for_balance_change(@agent[:wallet].address, agent_before)

    evidence = "0x" + "ab" * 32
    sub = @provider[:wallet].submit_bounty(bounty.id, evidence)
    puts "[ACCEPTANCE] bounty | submit | id=#{bounty.id}"

    # Retry award up to 15 times (Ponder indexer lag)
    awarded = nil
    15.times do |attempt|
      sleep 3
      begin
        awarded = @agent[:wallet].award_bounty(bounty.id, sub.id)
        break
      rescue StandardError => e
        if attempt < 14
          puts "[ACCEPTANCE] bounty award retry #{attempt + 1}: #{e.message}"
        else
          raise
        end
      end
    end
    expect(awarded).not_to be_nil
    expect(awarded.status).to eq("awarded")
    log_tx("bounty", "award", awarded.tx_hash) if awarded.respond_to?(:tx_hash) && awarded.tx_hash

    provider_after = wait_for_balance_change(@provider[:wallet].address, provider_before)
    agent_after = get_usdc_balance(@agent[:wallet].address)

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change("provider", provider_before, provider_after, amount * 0.99)
  end

  # ── Flow 6: Deposit ────────────────────────────────────────────────────────

  it "06 deposit lifecycle (place, return with full refund)" do
    amount = 2.0

    agent_before = get_usdc_balance(@agent[:wallet].address)

    permit = @agent[:wallet].sign_permit("deposit", amount)
    deposit = @agent[:wallet].place_deposit(
      @provider[:wallet].address, amount,
      expires_in_secs: 3600,
      permit: permit
    )
    expect(deposit.id).not_to be_nil
    expect(deposit.id).not_to be_empty
    log_tx("deposit", "place #{amount} USDC", deposit.tx_hash) if deposit.respond_to?(:tx_hash) && deposit.tx_hash

    agent_mid = wait_for_balance_change(@agent[:wallet].address, agent_before)
    assert_balance_change("agent locked", agent_before, agent_mid, -amount)

    returned = @provider[:wallet].return_deposit(deposit.id)
    expect(returned.tx_hash).to start_with("0x") if returned.respond_to?(:tx_hash) && returned.tx_hash
    log_tx("deposit", "return", returned.tx_hash) if returned.respond_to?(:tx_hash) && returned.tx_hash

    agent_after = wait_for_balance_change(@agent[:wallet].address, agent_mid)
    assert_balance_change("agent refund", agent_before, agent_after, 0)
  end

  # ── Flow 7: x402 (via /x402/prepare — no local HTTP server) ────────────────

  it "07 x402_prepare" do
    contracts = @agent[:wallet].get_contracts

    payment_required = {
      "scheme" => "exact",
      "network" => "eip155:84532",
      "amount" => "100000",
      "asset" => contracts.usdc,
      "payTo" => contracts.router,
      "maxTimeoutSeconds" => 60
    }
    encoded = Base64.strict_encode64(payment_required.to_json)

    # POST /x402/prepare via the wallet's authenticated transport
    # We access the transport directly since it handles EIP-712 auth
    data = @agent[:wallet].instance_variable_get(:@transport).post(
      "/x402/prepare",
      { payment_required: encoded, payer: @agent[:wallet].address }
    )

    expect(data).to include("hash")
    expect(data["hash"]).to start_with("0x")
    expect(data["hash"].length).to eq(66) # 0x + 64 hex chars
    expect(data).to include("from")
    expect(data).to include("to")
    expect(data).to include("value")

    puts "[ACCEPTANCE] x402 | prepare | hash=#{data["hash"][0, 18]}... | from=#{data["from"][0, 10]}..."
  end

  # ── Flow 8: AP2 Discovery ──────────────────────────────────────────────────

  it "08 ap2_discovery" do
    card = Remitmd::AgentCard.discover(API_URL)

    expect(card.name).not_to be_empty, "agent card should have a name"
    expect(card.url).not_to be_empty, "agent card should have a URL"
    expect(card.skills.length).to be > 0, "agent card should have skills"
    expect(card.x402).not_to be_empty, "agent card should have x402 config"

    puts "[ACCEPTANCE] ap2-discovery | name=#{card.name} | skills=#{card.skills.length} | x402=#{!card.x402.empty?}"
  end

  # ── Flow 9: AP2 Payment ────────────────────────────────────────────────────

  it "09 ap2_payment" do
    amount = 1.0

    agent_before = get_usdc_balance(@agent[:wallet].address)
    provider_before = get_usdc_balance(@provider[:wallet].address)

    card = Remitmd::AgentCard.discover(API_URL)
    permit = @agent[:wallet].sign_permit("direct", amount)

    signer = @agent[:wallet].instance_variable_get(:@signer)
    a2a = Remitmd::A2AClient.from_card(card, signer, chain: "base-sepolia")
    task = a2a.send(
      to: @provider[:wallet].address,
      amount: amount,
      memo: "acceptance-ap2",
      permit: permit
    )

    expect(task.status.state).not_to eq("failed"), "A2A task failed: state=#{task.status.state}"
    tx_hash = task.tx_hash
    expect(tx_hash).not_to be_nil
    expect(tx_hash).to start_with("0x")
    log_tx("ap2-payment", "#{amount} USDC via A2A", tx_hash)

    agent_after = wait_for_balance_change(@agent[:wallet].address, agent_before)
    provider_after = get_usdc_balance(@provider[:wallet].address)

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change("provider", provider_before, provider_after, amount * 0.99)
  end
end
