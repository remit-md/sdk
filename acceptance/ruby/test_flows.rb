#!/usr/bin/env ruby
# frozen_string_literal: true

# Remit SDK Acceptance -- Ruby: 9 flows against Base Sepolia.
#
# Flows: Direct, Escrow, Tab (2 charges), Stream, Bounty, Deposit, x402 Weather,
# AP2 Discovery, AP2 Payment.
#
# Usage:
#   ACCEPTANCE_API_URL=https://testnet.remit.md ruby test_flows.rb

$LOAD_PATH.unshift(File.join(__dir__, "../../ruby/lib"))
require "remitmd"
require "net/http"
require "json"
require "securerandom"
require "uri"
require "openssl"

# ─── Config ──────────────────────────────────────────────────────────────────────
API_URL = ENV.fetch("ACCEPTANCE_API_URL", "https://testnet.remit.md")
API_BASE = "#{API_URL}/api/v1"
RPC_URL = ENV.fetch("ACCEPTANCE_RPC_URL", "https://sepolia.base.org")
CHAIN_ID = 84_532
USDC_ADDRESS = "0x2d846325766921935f37d5b4478196d3ef93707c"
FEE_WALLET = "0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38"

# ─── Colors ──────────────────────────────────────────────────────────────────────
GREEN = "\033[0;32m"
RED = "\033[0;31m"
CYAN = "\033[0;36m"
BOLD = "\033[1m"
RESET = "\033[0m"

RESULTS = {}

def log_pass(flow, msg = nil)
  extra = msg ? " -- #{msg}" : ""
  puts "#{GREEN}[PASS]#{RESET} #{flow}#{extra}"
  RESULTS[flow] = "PASS"
end

def log_fail(flow, msg)
  puts "#{RED}[FAIL]#{RESET} #{flow} -- #{msg}"
  RESULTS[flow] = "FAIL"
end

def log_info(msg)
  puts "#{CYAN}[INFO]#{RESET} #{msg}"
end

def log_tx(flow, step, tx_hash)
  return if tx_hash.nil? || tx_hash.empty?
  puts "  [TX] #{flow} | #{step} | https://sepolia.basescan.org/tx/#{tx_hash}"
end

# ─── Helpers ─────────────────────────────────────────────────────────────────────

@contracts_cache = nil

def fetch_contracts
  return @contracts_cache if @contracts_cache
  uri = URI("#{API_BASE}/contracts")
  resp = Net::HTTP.get_response(uri)
  raise "GET /contracts: #{resp.code} #{resp.body}" unless resp.code == "200"
  @contracts_cache = JSON.parse(resp.body)
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

def wait_for_balance_change(address, before, timeout: 30)
  deadline = Time.now + timeout
  while Time.now < deadline
    current = get_usdc_balance(address)
    return current if (current - before).abs > 0.0001
    sleep 2
  end
  get_usdc_balance(address)
end

def create_test_wallet
  key_hex = SecureRandom.hex(32)
  contracts = fetch_contracts
  # Ruby SDK expects api_url to include /api/v1
  base_url = API_URL.end_with?("/api/v1") ? API_URL : "#{API_URL}/api/v1"
  wallet = Remitmd::RemitWallet.new(
    private_key: "0x#{key_hex}",
    chain: "base_sepolia",
    api_url: base_url,
    router_address: contracts["router"]
  )
  { wallet: wallet, key_hex: key_hex }
end

def fund_wallet(tw, amount)
  tw[:wallet].mint(amount)
  wait_for_balance_change(tw[:wallet].address, 0)
end

# ─── EIP-2612 Permit Signing ────────────────────────────────────────────────────

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
  domain_type_hash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
  name_hash = keccak256("USD Coin")
  version_hash = keccak256("2")
  usdc_padded = pad_address(USDC_ADDRESS)

  domain_data = domain_type_hash + name_hash + version_hash + pad_uint256(CHAIN_ID) + usdc_padded
  domain_sep = keccak256(domain_data)

  permit_type_hash = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
  struct_data = permit_type_hash + pad_address(owner) + pad_address(spender) +
                pad_uint256(value) + pad_uint256(nonce) + pad_uint256(deadline)
  struct_hash = keccak256(struct_data)

  final_data = "\x19\x01".b + domain_sep + struct_hash
  digest = keccak256(final_data)

  signer = Remitmd::PrivateKeySigner.new("0x#{key_hex}")
  sig_hex = signer.sign(digest)

  sig_bytes = [sig_hex.delete_prefix("0x")].pack("H*")
  r = "0x#{sig_bytes[0, 32].unpack1("H*")}"
  s = "0x#{sig_bytes[32, 32].unpack1("H*")}"
  v = sig_bytes[64].ord

  Remitmd::PermitSignature.new(value: value, deadline: deadline, v: v, r: r, s: s)
end

# ─── Flow 1: Direct Payment ─────────────────────────────────────────────────────
def flow_direct(agent, provider)
  flow = "1. Direct Payment"
  contracts = fetch_contracts
  deadline = Time.now.to_i + 3600
  permit = sign_usdc_permit(
    agent[:key_hex], agent[:wallet].address, contracts["router"],
    2_000_000, 0, deadline
  )

  tx = agent[:wallet].pay(provider[:wallet].address, 1.0, memo: "ruby-acceptance", permit: permit)
  raise "bad tx_hash: #{tx.tx_hash}" unless tx.tx_hash&.start_with?("0x")
  log_tx(flow, "pay", tx.tx_hash)
  log_pass(flow, "tx=#{tx.tx_hash[0, 18]}...")
end

# ─── Flow 2: Escrow ─────────────────────────────────────────────────────────────
def flow_escrow(agent, provider)
  flow = "2. Escrow"
  contracts = fetch_contracts
  deadline = Time.now.to_i + 3600
  permit = sign_usdc_permit(
    agent[:key_hex], agent[:wallet].address, contracts["escrow"],
    6_000_000, 0, deadline
  )

  escrow = agent[:wallet].create_escrow(provider[:wallet].address, 5.0, permit: permit)
  raise "escrow should have an id" if escrow.id.nil? || escrow.id.empty?

  wait_for_balance_change(agent[:wallet].address, get_usdc_balance(agent[:wallet].address))
  sleep 3

  provider[:wallet].claim_start(escrow.id)
  sleep 3

  agent[:wallet].release_escrow(escrow.id)
  log_pass(flow, "escrow_id=#{escrow.id}")
end

# ─── Flow 3: Metered Tab (2 charges) ────────────────────────────────────────────
def flow_tab(agent, provider)
  flow = "3. Metered Tab"
  contracts = fetch_contracts
  tab_contract = contracts["tab"]
  deadline = Time.now.to_i + 3600
  permit = sign_usdc_permit(
    agent[:key_hex], agent[:wallet].address, tab_contract,
    11_000_000, 0, deadline
  )

  agent_before = get_usdc_balance(agent[:wallet].address)

  tab = agent[:wallet].create_tab(provider[:wallet].address, 10.0, 0.10, permit: permit)
  raise "tab should have an id" if tab.id.nil? || tab.id.empty?

  wait_for_balance_change(agent[:wallet].address, agent_before)

  # Charge 1: $2
  sig1 = provider[:wallet].sign_tab_charge(tab_contract, tab.id, 2_000_000, 1)
  charge1 = provider[:wallet].charge_tab(tab.id, 2.0, 2.0, 1, sig1)
  raise "charge1 tab_id mismatch" unless charge1.tab_id == tab.id

  # Charge 2: $1 more (cumulative $3)
  sig2 = provider[:wallet].sign_tab_charge(tab_contract, tab.id, 3_000_000, 2)
  charge2 = provider[:wallet].charge_tab(tab.id, 1.0, 3.0, 2, sig2)
  raise "expected call_count=2, got #{charge2.call_count}" unless charge2.call_count == 2

  # Close with final state ($3, 2 calls)
  close_sig = provider[:wallet].sign_tab_charge(tab_contract, tab.id, 3_000_000, 2)
  agent[:wallet].close_tab(tab.id, final_amount: 3.0, provider_sig: close_sig)

  log_pass(flow, "tab_id=#{tab.id}, charged=$3, 2 charges")
end

# ─── Flow 4: Stream ─────────────────────────────────────────────────────────────
def flow_stream(agent, provider)
  flow = "4. Stream"
  contracts = fetch_contracts
  deadline = Time.now.to_i + 3600
  permit = sign_usdc_permit(
    agent[:key_hex], agent[:wallet].address, contracts["stream"],
    6_000_000, 0, deadline
  )

  stream = agent[:wallet].create_stream(provider[:wallet].address, 0.01, 5.0, permit: permit)
  raise "stream should have an id" if stream.id.nil? || stream.id.empty?

  sleep 5

  closed = agent[:wallet].close_stream(stream.id)
  log_pass(flow, "stream_id=#{stream.id}")
end

# ─── Flow 5: Bounty ─────────────────────────────────────────────────────────────
def flow_bounty(agent, provider)
  flow = "5. Bounty"
  contracts = fetch_contracts
  deadline = Time.now.to_i + 3600
  permit = sign_usdc_permit(
    agent[:key_hex], agent[:wallet].address, contracts["bounty"],
    6_000_000, 0, deadline
  )

  bounty = agent[:wallet].create_bounty(5.0, "ruby-acceptance-bounty", deadline, permit: permit)
  raise "bounty should have an id" if bounty.id.nil? || bounty.id.empty?

  wait_for_balance_change(agent[:wallet].address, get_usdc_balance(agent[:wallet].address))

  evidence_hash = "0x" + "ab" * 32
  submission = provider[:wallet].submit_bounty(bounty.id, evidence_hash)
  raise "submission should have an id" if submission.id.nil?
  sleep 5

  awarded = agent[:wallet].award_bounty(bounty.id, submission.id)
  log_pass(flow, "bounty_id=#{bounty.id}")
end

# ─── Flow 6: Deposit ────────────────────────────────────────────────────────────
def flow_deposit(agent, provider)
  flow = "6. Deposit"
  contracts = fetch_contracts
  deadline = Time.now.to_i + 3600
  permit = sign_usdc_permit(
    agent[:key_hex], agent[:wallet].address, contracts["deposit"],
    6_000_000, 0, deadline
  )

  agent_before = get_usdc_balance(agent[:wallet].address)

  deposit = agent[:wallet].place_deposit(provider[:wallet].address, 5.0,
                                          expires_in_secs: 3600, permit: permit)
  raise "deposit should have an id" if deposit.id.nil? || deposit.id.empty?

  wait_for_balance_change(agent[:wallet].address, agent_before)

  provider[:wallet].return_deposit(deposit.id)
  log_pass(flow, "deposit_id=#{deposit.id}")
end

# ─── Flow 7: x402 Weather ───────────────────────────────────────────────────────
def flow_x402_weather(agent)
  flow = "7. x402 Weather"

  # Step 1: Hit the paywall
  uri = URI("#{API_BASE}/x402/demo")
  resp = Net::HTTP.get_response(uri)
  unless resp.code == "402"
    log_fail(flow, "expected 402, got #{resp.code}")
    return
  end

  # Parse X-Payment headers
  scheme = resp["x-payment-scheme"] || "exact"
  network = resp["x-payment-network"] || "eip155:#{CHAIN_ID}"
  amount_str = resp["x-payment-amount"] || "5000000"
  asset = resp["x-payment-asset"] || USDC_ADDRESS
  pay_to = resp["x-payment-payto"] || ""
  amount_raw = amount_str.to_i

  log_info("  Paywall: #{scheme} | $#{"%.2f" % (amount_raw / 1e6)} USDC | network=#{network}")

  # Step 2: Sign EIP-3009 TransferWithAuthorization
  chain_id = network.include?(":") ? network.split(":")[1].to_i : CHAIN_ID
  now_secs = Time.now.to_i
  valid_before = now_secs + 300
  nonce_bytes = SecureRandom.random_bytes(32)
  nonce_hex = "0x#{nonce_bytes.unpack1("H*")}"

  # EIP-712 domain: USD Coin / version 2
  domain_type_hash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
  d_name_hash = keccak256("USD Coin")
  d_version_hash = keccak256("2")
  domain_data = domain_type_hash + d_name_hash + d_version_hash + pad_uint256(chain_id) + pad_address(asset)
  domain_sep = keccak256(domain_data)

  # TransferWithAuthorization struct
  type_hash = keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
  struct_data = type_hash + pad_address(agent[:wallet].address) + pad_address(pay_to) +
                pad_uint256(amount_raw) + pad_uint256(0) + pad_uint256(valid_before) + nonce_bytes
  struct_hash = keccak256(struct_data)

  final_data = "\x19\x01".b + domain_sep + struct_hash
  digest = keccak256(final_data)

  signer = Remitmd::PrivateKeySigner.new("0x#{agent[:key_hex]}")
  signature = signer.sign(digest)

  # Step 3: Settle via authenticated POST
  settle_body = {
    paymentPayload: {
      scheme: scheme,
      network: network,
      x402Version: 1,
      payload: {
        signature: signature,
        authorization: {
          from: agent[:wallet].address,
          to: pay_to,
          value: amount_str,
          validAfter: "0",
          validBefore: valid_before.to_s,
          nonce: nonce_hex,
        },
      },
    },
    paymentRequired: {
      scheme: scheme,
      network: network,
      amount: amount_str,
      asset: asset,
      payTo: pay_to,
      maxTimeoutSeconds: 300,
    },
  }

  settle_uri = URI("#{API_BASE}/x402/settle")
  settle_http = Net::HTTP.new(settle_uri.host, settle_uri.port)
  settle_http.use_ssl = settle_uri.scheme == "https"
  settle_req = Net::HTTP::Post.new(settle_uri.path)
  settle_req["Content-Type"] = "application/json"
  settle_req.body = settle_body.to_json
  settle_resp = settle_http.request(settle_req)
  settle_result = JSON.parse(settle_resp.body)
  tx_hash = settle_result["transactionHash"]

  unless tx_hash && !tx_hash.empty?
    log_fail(flow, "settle returned no tx_hash")
    return
  end
  log_tx(flow, "settle", tx_hash)

  # Step 4: Fetch weather with payment proof
  weather_uri = URI("#{API_BASE}/x402/demo")
  weather_req = Net::HTTP::Get.new(weather_uri)
  weather_req["X-Payment-Response"] = tx_hash
  weather_http = Net::HTTP.new(weather_uri.host, weather_uri.port)
  weather_http.use_ssl = weather_uri.scheme == "https"
  weather_resp = weather_http.request(weather_req)

  unless weather_resp.code == "200"
    log_fail(flow, "weather fetch returned #{weather_resp.code}")
    return
  end

  weather = JSON.parse(weather_resp.body)
  loc = weather["location"] || {}
  cur = weather["current"] || {}
  cond = cur["condition"] || {}

  city = loc["name"] || "Unknown"
  temp_f = cur["temp_f"] || "?"
  temp_c = cur["temp_c"] || "?"
  condition = cond.is_a?(Hash) ? (cond["text"] || "Unknown") : (cur["condition"] || "Unknown")

  puts
  puts "#{CYAN}+---------------------------------------------+#{RESET}"
  puts "#{CYAN}|#{RESET}  #{BOLD}x402 Weather Report#{RESET} (paid $#{"%.2f" % (amount_raw / 1e6)} USDC)   #{CYAN}|#{RESET}"
  puts "#{CYAN}+---------------------------------------------+#{RESET}"
  printf "#{CYAN}|#{RESET}  City:        %-29s#{CYAN}|#{RESET}\n", city
  printf "#{CYAN}|#{RESET}  Temperature: %sF / %sC%s#{CYAN}|#{RESET}\n", temp_f, temp_c,
         " " * [0, 22 - temp_f.to_s.length - temp_c.to_s.length].max
  printf "#{CYAN}|#{RESET}  Condition:   %-29s#{CYAN}|#{RESET}\n", condition
  puts "#{CYAN}+---------------------------------------------+#{RESET}"
  puts

  log_pass(flow, "city=#{city}, tx=#{tx_hash[0, 18]}...")
end

# ─── Flow 8: AP2 Discovery ──────────────────────────────────────────────────────
def flow_ap2_discovery
  flow = "8. AP2 Discovery"
  card = Remitmd::AgentCard.discover(API_URL)

  puts
  puts "#{CYAN}+---------------------------------------------+#{RESET}"
  puts "#{CYAN}|#{RESET}  #{BOLD}A2A Agent Card#{RESET}                            #{CYAN}|#{RESET}"
  puts "#{CYAN}+---------------------------------------------+#{RESET}"
  printf "#{CYAN}|#{RESET}  Name:     %-32s#{CYAN}|#{RESET}\n", card.name
  printf "#{CYAN}|#{RESET}  Version:  %-32s#{CYAN}|#{RESET}\n", card.version
  printf "#{CYAN}|#{RESET}  Protocol: %-32s#{CYAN}|#{RESET}\n", card.protocol_version
  url_display = card.url.length > 32 ? card.url[0, 32] : card.url
  printf "#{CYAN}|#{RESET}  URL:      %-32s#{CYAN}|#{RESET}\n", url_display
  if card.skills && !card.skills.empty?
    printf "#{CYAN}|#{RESET}  Skills:   %d total%25s#{CYAN}|#{RESET}\n", card.skills.size, ""
    card.skills.first(5).each do |s|
      name = s.name.length > 38 ? s.name[0, 38] : s.name
      printf "#{CYAN}|#{RESET}    - %-38s#{CYAN}|#{RESET}\n", name
    end
  end
  puts "#{CYAN}+---------------------------------------------+#{RESET}"
  puts

  raise "agent card should have a name" if card.name.nil? || card.name.empty?
  log_pass(flow, "name=#{card.name}")
end

# ─── Flow 9: AP2 Payment ────────────────────────────────────────────────────────
def flow_ap2_payment(agent, provider)
  flow = "9. AP2 Payment"
  card = Remitmd::AgentCard.discover(API_URL)
  contracts = fetch_contracts

  signer = Remitmd::PrivateKeySigner.new("0x#{agent[:key_hex]}")

  mandate = Remitmd::IntentMandate.new(
    mandate_id: SecureRandom.hex(16),
    expires_at: "2099-12-31T23:59:59Z",
    issuer: agent[:wallet].address,
    max_amount: "5.00",
    currency: "USDC"
  )

  a2a = Remitmd::A2AClient.from_card(card, signer, chain: "base-sepolia",
                                       verifying_contract: contracts["router"])
  task = a2a.send(to: provider[:wallet].address, amount: 1.0,
                  memo: "ruby-acceptance-a2a", mandate: mandate)
  raise "a2a task should have an id" if task.id.nil? || task.id.empty?

  tx_hash = task.tx_hash
  log_tx(flow, "a2a-pay", tx_hash) if tx_hash

  # Verify persistence
  fetched = a2a.get(task.id)
  raise "fetched task id mismatch" unless fetched.id == task.id

  log_pass(flow, "task_id=#{task.id}, state=#{task.status.state}")
end

# ─── Main ────────────────────────────────────────────────────────────────────────
puts
puts "#{BOLD}Ruby SDK -- 9 Flow Acceptance Suite#{RESET}"
puts "  API: #{API_URL}"
puts "  RPC: #{RPC_URL}"
puts

log_info("Creating agent wallet...")
agent = create_test_wallet
log_info("  Agent:    #{agent[:wallet].address}")

log_info("Creating provider wallet...")
provider = create_test_wallet
log_info("  Provider: #{provider[:wallet].address}")

log_info("Minting $100 USDC to agent...")
fund_wallet(agent, 100)
bal = get_usdc_balance(agent[:wallet].address)
log_info("  Agent balance: $#{"%.2f" % bal}")

log_info("Minting $100 USDC to provider...")
fund_wallet(provider, 100)
bal2 = get_usdc_balance(provider[:wallet].address)
log_info("  Provider balance: $#{"%.2f" % bal2}")
puts

flows = [
  ["1. Direct Payment", -> { flow_direct(agent, provider) }],
  ["2. Escrow",         -> { flow_escrow(agent, provider) }],
  ["3. Metered Tab",    -> { flow_tab(agent, provider) }],
  ["4. Stream",         -> { flow_stream(agent, provider) }],
  ["5. Bounty",         -> { flow_bounty(agent, provider) }],
  ["6. Deposit",        -> { flow_deposit(agent, provider) }],
  ["7. x402 Weather",   -> { flow_x402_weather(agent) }],
  ["8. AP2 Discovery",  -> { flow_ap2_discovery }],
  ["9. AP2 Payment",    -> { flow_ap2_payment(agent, provider) }],
]

flows.each do |name, fn|
  begin
    fn.call
  rescue => e
    log_fail(name, "#{e.class}: #{e.message}")
    $stderr.puts e.backtrace.first(10).join("\n")
  end
end

# Summary
passed = RESULTS.values.count("PASS")
failed = RESULTS.values.count("FAIL")
puts
puts "#{BOLD}Ruby Summary: #{GREEN}#{passed} passed#{RESET}, #{RED}#{failed} failed#{RESET} / 9 flows"
puts({ passed: passed, failed: failed, skipped: 9 - passed - failed }.to_json)
exit(failed > 0 ? 1 : 0)
