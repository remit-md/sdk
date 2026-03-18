# frozen_string_literal: true

# Ruby SDK acceptance tests: payDirect + escrow lifecycle on live Base Sepolia.
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

API_URL = ENV.fetch("ACCEPTANCE_API_URL", "https://remit.md")
RPC_URL = ENV.fetch("ACCEPTANCE_RPC_URL", "https://sepolia.base.org")
USDC_ADDRESS = "0x142aD61B8d2edD6b3807D9266866D97C35Ee0317"
FEE_WALLET = "0xd3f721BDF92a2bB5Dd8d2FE2AFC03aFE5629B420"
CHAIN_ID = 84532

# ─── Helpers ──────────────────────────────────────────────────────────────────

def fetch_contracts
  @contracts_cache ||= begin
    uri = URI("#{API_URL}/api/v0/contracts")
    resp = Net::HTTP.get_response(uri)
    raise "GET /contracts: #{resp.code} #{resp.body}" unless resp.code == "200"
    JSON.parse(resp.body)
  end
end

def create_test_wallet
  key_hex = SecureRandom.hex(32)
  contracts = fetch_contracts
  wallet = Remitmd::RemitWallet.new(
    private_key: "0x#{key_hex}",
    chain: "base_sepolia",
    api_url: API_URL,
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
    "#{label}: expected delta #{expected}, got #{actual} (before=#{before}, after=#{after})"
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

RSpec.describe "Acceptance", :acceptance do
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
