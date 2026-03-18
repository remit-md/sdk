# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"

module Remitmd
  # Primary remit.md client. All payment operations are methods on RemitWallet.
  #
  # @example Quickstart
  #   wallet = Remitmd::RemitWallet.new(private_key: ENV["REMITMD_KEY"])
  #   tx = wallet.pay("0xRecipient...", 1.50)
  #   puts tx.tx_hash
  #
  # @example From environment
  #   wallet = Remitmd::RemitWallet.from_env
  #
  # Private keys are held only by the Signer and never appear in inspect/to_s.
  class RemitWallet
    MIN_AMOUNT = BigDecimal("0.000001") # 1 micro-USDC

    # @param private_key [String, nil] 0x-prefixed hex private key
    # @param signer [Signer, nil]      custom signer (pass instead of private_key)
    # @param chain [String]            chain name — "base", "base_sepolia"
    # @param api_url [String, nil]     override API base URL
    # @param transport [Object, nil]   inject mock transport (used by MockRemit)
    def initialize(private_key: nil, signer: nil, chain: "base", api_url: nil, router_address: nil, transport: nil)
      if transport
        # MockRemit path: transport + signer injected directly
        @signer    = signer
        @transport = transport
        return
      end

      if private_key.nil? && signer.nil?
        raise ArgumentError, "Provide either :private_key or :signer"
      end
      if !private_key.nil? && !signer.nil?
        raise ArgumentError, "Provide :private_key OR :signer, not both"
      end

      @signer = signer || PrivateKeySigner.new(private_key)
      # Normalize to the base chain name (strip testnet suffix) for use in pay body.
      # The server accepts "base" — not "base_sepolia" etc.
      @chain  = chain.sub(/_sepolia\z/, "").sub(/-sepolia\z/, "")
      cfg     = CHAIN_CONFIG.fetch(chain) do
        raise ArgumentError, "Unknown chain: #{chain}. Valid: #{CHAIN_CONFIG.keys.join(", ")}"
      end
      base_url       = api_url || cfg[:url]
      chain_id       = cfg[:chain_id]
      router_address ||= ""
      @transport = HttpTransport.new(
        base_url:       base_url,
        signer:         @signer,
        chain_id:       chain_id,
        router_address: router_address
      )
    end

    # Build a RemitWallet from environment variables.
    # Reads: REMITMD_PRIVATE_KEY, REMITMD_CHAIN, REMITMD_API_URL, REMITMD_ROUTER_ADDRESS.
    def self.from_env
      key            = ENV.fetch("REMITMD_PRIVATE_KEY") { raise ArgumentError, "REMITMD_PRIVATE_KEY not set" }
      chain          = ENV.fetch("REMITMD_CHAIN", "base")
      api_url        = ENV["REMITMD_API_URL"]
      router_address = ENV["REMITMD_ROUTER_ADDRESS"]
      new(private_key: key, chain: chain, api_url: api_url, router_address: router_address)
    end

    # The Ethereum address associated with this wallet.
    def address
      @signer.address
    end

    def inspect
      "#<Remitmd::RemitWallet address=#{address}>"
    end

    alias to_s inspect

    # ─── Contracts ─────────────────────────────────────────────────────────────

    # Get deployed contract addresses. Cached for the lifetime of this client.
    # @return [ContractAddresses]
    def get_contracts
      @contracts_cache ||= ContractAddresses.new(@transport.get("/contracts"))
    end

    # ─── Balance & Analytics ─────────────────────────────────────────────────

    # Fetch the current USDC balance.
    # @return [Balance]
    def balance
      Balance.new(@transport.get("/wallet/balance"))
    end

    # Fetch transaction history.
    # @param limit [Integer] max results per page
    # @param offset [Integer] pagination offset
    # @return [TransactionList]
    def history(limit: 50, offset: 0)
      data = @transport.get("/wallet/history?limit=#{limit}&offset=#{offset}")
      TransactionList.new(data)
    end

    # Fetch the on-chain reputation for an address.
    # @param addr [String] 0x-prefixed Ethereum address
    # @return [Reputation]
    def reputation(addr)
      validate_address!(addr)
      Reputation.new(@transport.get("/reputation/#{addr}"))
    end

    # Fetch monthly spending summary.
    # @return [SpendingSummary]
    def spending_summary
      SpendingSummary.new(@transport.get("/wallet/spending"))
    end

    # Fetch operator-set budget limits and remaining allowances.
    # @return [Budget]
    def remaining_budget
      Budget.new(@transport.get("/wallet/budget"))
    end

    # ─── Direct Payment ───────────────────────────────────────────────────────

    # Send USDC directly to another address.
    # @param to [String] recipient 0x-prefixed address
    # @param amount [Numeric, BigDecimal] amount in USDC (e.g. 1.50)
    # @param memo [String, nil] optional note
    # @param permit [PermitSignature, nil] optional EIP-2612 permit for gasless approval
    # @return [Transaction]
    def pay(to, amount, memo: nil, permit: nil)
      validate_address!(to)
      validate_amount!(amount)
      nonce = SecureRandom.hex(16)
      body = { to: to, amount: amount.to_s, task: memo || "", chain: @chain, nonce: nonce, signature: "0x" }
      body[:permit] = permit.to_h if permit
      Transaction.new(@transport.post("/payments/direct", body))
    end

    # ─── Escrow ───────────────────────────────────────────────────────────────

    # Create a new escrow (funds held until release or cancel).
    # @param payee [String] 0x-prefixed payee address
    # @param amount [Numeric] amount in USDC
    # @param memo [String, nil] optional note
    # @param expires_in_secs [Integer, nil] optional expiry in seconds from now
    # @param permit [PermitSignature, nil] optional EIP-2612 permit for gasless approval
    # @return [Escrow]
    def create_escrow(payee, amount, memo: nil, expires_in_secs: nil, permit: nil)
      validate_address!(payee)
      validate_amount!(amount)

      # Step 1: create invoice on server.
      invoice_id = SecureRandom.hex(16)
      nonce      = SecureRandom.hex(16)
      inv_body = {
        id: invoice_id, chain: @chain,
        from_agent: address.downcase, to_agent: payee.downcase,
        amount: amount.to_s, type: "escrow",
        task: memo || "", nonce: nonce, signature: "0x"
      }
      inv_body[:escrow_timeout] = expires_in_secs if expires_in_secs
      @transport.post("/invoices", inv_body)

      # Step 2: fund the escrow.
      esc_body = { invoice_id: invoice_id }
      esc_body[:permit] = permit.to_h if permit
      Escrow.new(@transport.post("/escrows", esc_body))
    end

    # Release an escrow to the payee.
    # @param escrow_id [String]
    # @param memo [String, nil]
    # @return [Transaction]
    def release_escrow(escrow_id, memo: nil)
      body = memo ? { memo: memo } : {}
      Transaction.new(@transport.post("/escrows/#{escrow_id}/release", body))
    end

    # Cancel an escrow and refund the payer.
    # @param escrow_id [String]
    # @return [Transaction]
    def cancel_escrow(escrow_id)
      Transaction.new(@transport.post("/escrows/#{escrow_id}/cancel", {}))
    end

    # Signal the provider has started work on an escrow.
    # @param escrow_id [String]
    # @return [Escrow]
    def claim_start(escrow_id)
      Escrow.new(@transport.post("/escrows/#{escrow_id}/claim-start", {}))
    end

    # Fetch escrow details.
    # @param escrow_id [String]
    # @return [Escrow]
    def get_escrow(escrow_id)
      Escrow.new(@transport.get("/escrows/#{escrow_id}"))
    end

    # ─── Tabs (Metered Billing) ───────────────────────────────────────────────

    # Open a payment tab for off-chain metered billing.
    # @param provider [String] 0x-prefixed provider address
    # @param limit_amount [Numeric] maximum tab credit in USDC
    # @param per_unit [Numeric] USDC per API call
    # @param expires_in_secs [Integer] optional expiry duration in seconds (default: 86400)
    # @param permit [PermitSignature, nil] optional EIP-2612 permit for gasless approval
    # @return [Tab]
    def create_tab(provider, limit_amount, per_unit = 0.0, expires_in_secs: 86_400, permit: nil)
      validate_address!(provider)
      validate_amount!(limit_amount)
      body = {
        chain: @chain,
        provider: provider,
        limit_amount: limit_amount.to_f,
        per_unit: per_unit.to_f,
        expiry: Time.now.to_i + expires_in_secs
      }
      body[:permit] = permit.to_h if permit
      Tab.new(@transport.post("/tabs", body))
    end

    # Charge a tab using an EIP-712 signed provider authorization.
    # @param tab_id [String]
    # @param amount [Numeric] charge amount in USDC
    # @param cumulative [Numeric] cumulative total charged so far
    # @param call_count [Integer] total number of calls so far
    # @param provider_sig [String] EIP-712 signature from the provider
    # @return [TabDebit]
    def charge_tab(tab_id, amount, cumulative, call_count, provider_sig)
      body = {
        amount: amount.to_f,
        cumulative: cumulative.to_f,
        call_count: call_count,
        provider_sig: provider_sig
      }
      TabDebit.new(@transport.post("/tabs/#{tab_id}/charge", body))
    end

    # Record a debit against an open tab (off-chain, no gas).
    # @param tab_id [String]
    # @param amount [Numeric] amount in USDC
    # @param memo [String] description of this debit
    # @return [TabDebit]
    def debit_tab(tab_id, amount, memo = "")
      validate_amount!(amount)
      body = { amount: amount.to_s, memo: memo }
      TabDebit.new(@transport.post("/tabs/#{tab_id}/debit", body))
    end

    # Close a tab on-chain, settling the final balance.
    # @param tab_id [String]
    # @param final_amount [Numeric, nil] final settlement amount in USDC
    # @param provider_sig [String, nil] EIP-712 signature from the provider
    # @return [Tab]
    def close_tab(tab_id, final_amount: nil, provider_sig: nil)
      body = {}
      body[:final_amount] = final_amount.to_f if final_amount
      body[:provider_sig] = provider_sig if provider_sig
      Tab.new(@transport.post("/tabs/#{tab_id}/close", body))
    end

    # Settle a tab on-chain, paying the net balance.
    # @param tab_id [String]
    # @return [Tab]
    # @deprecated Use {#close_tab} instead
    def settle_tab(tab_id)
      close_tab(tab_id)
    end

    # Sign an EIP-712 TabCharge message as the provider.
    # Domain: RemitTab/1/<chainId>/<tabContract>
    # Type: TabCharge(bytes32 tabId, uint96 totalCharged, uint32 callCount)
    # @param tab_contract [String] tab contract address
    # @param tab_id [String] UUID of the tab
    # @param total_charged_base_units [Integer] total charged in USDC base units (6 decimals)
    # @param call_count [Integer] total call count
    # @param chain_id [Integer] chain ID (default: 84532 for Base Sepolia)
    # @return [String] 0x-prefixed 65-byte hex signature
    def sign_tab_charge(tab_contract, tab_id, total_charged_base_units, call_count, chain_id: 84_532)
      # Domain separator for RemitTab
      domain_type_hash = keccak256_raw(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
      )
      name_hash = keccak256_raw("RemitTab")
      version_hash = keccak256_raw("1")
      chain_id_enc = abi_uint256(chain_id)
      contract_enc = abi_address(tab_contract)

      domain_data = domain_type_hash + name_hash + version_hash + chain_id_enc + contract_enc
      domain_sep = keccak256_raw(domain_data)

      # TabCharge struct hash
      type_hash = keccak256_raw(
        "TabCharge(bytes32 tabId,uint96 totalCharged,uint32 callCount)"
      )

      # Encode tabId as bytes32: ASCII bytes right-padded with zeroes
      tab_id_bytes = tab_id.b.ljust(32, "\x00".b)

      struct_data = type_hash + tab_id_bytes + abi_uint256(total_charged_base_units) + abi_uint256(call_count)
      struct_hash = keccak256_raw(struct_data)

      # EIP-712 digest
      digest = keccak256_raw("\x19\x01".b + domain_sep + struct_hash)

      @signer.sign(digest)
    end

    # ─── Streams (Payment Streaming) ─────────────────────────────────────────

    # Create a real-time payment stream.
    # @param payee [String] 0x-prefixed address of the stream recipient
    # @param rate_per_second [Numeric] USDC per second
    # @param max_total [Numeric] maximum total USDC for the stream
    # @param permit [PermitSignature, nil] optional EIP-2612 permit for gasless approval
    # @return [Stream]
    def create_stream(payee, rate_per_second, max_total, permit: nil)
      validate_address!(payee)
      validate_amount!(rate_per_second)
      validate_amount!(max_total)
      body = {
        chain: @chain,
        payee: payee,
        rate_per_second: rate_per_second.to_s,
        max_total: max_total.to_s
      }
      body[:permit] = permit.to_h if permit
      Stream.new(@transport.post("/streams", body))
    end

    # Close an active payment stream.
    # @param stream_id [String]
    # @return [Stream]
    def close_stream(stream_id)
      Stream.new(@transport.post("/streams/#{stream_id}/close", {}))
    end

    # Withdraw accrued funds from a stream.
    # @param stream_id [String]
    # @return [Transaction]
    def withdraw_stream(stream_id)
      Transaction.new(@transport.post("/streams/#{stream_id}/withdraw", {}))
    end

    # ─── Bounties ─────────────────────────────────────────────────────────────

    # Post a bounty for any agent to claim by completing a task.
    # @param amount [Numeric] bounty amount in USDC
    # @param task_description [String] task description
    # @param deadline [Integer] deadline as Unix timestamp
    # @param max_attempts [Integer] maximum submission attempts (default: 10)
    # @param permit [PermitSignature, nil] optional EIP-2612 permit for gasless approval
    # @return [Bounty]
    def create_bounty(amount, task_description, deadline, max_attempts: 10, permit: nil)
      validate_amount!(amount)
      body = {
        chain: @chain,
        amount: amount.to_f,
        task_description: task_description,
        deadline: deadline,
        max_attempts: max_attempts
      }
      body[:permit] = permit.to_h if permit
      Bounty.new(@transport.post("/bounties", body))
    end

    # Submit evidence to claim a bounty.
    # @param bounty_id [String]
    # @param evidence_hash [String] 0x-prefixed hash of the evidence
    # @return [BountySubmission]
    def submit_bounty(bounty_id, evidence_hash)
      BountySubmission.new(@transport.post("/bounties/#{bounty_id}/submit", { evidence_hash: evidence_hash }))
    end

    # Award a bounty to a specific submission.
    # @param bounty_id [String]
    # @param submission_id [Integer] ID of the winning submission
    # @return [Bounty]
    def award_bounty(bounty_id, submission_id)
      Bounty.new(@transport.post("/bounties/#{bounty_id}/award", { submission_id: submission_id }))
    end

    # List bounties with optional filters.
    # @param status [String, nil] filter by status (open, claimed, awarded, expired)
    # @param poster [String, nil] filter by poster wallet address
    # @param submitter [String, nil] filter by submitter wallet address
    # @param limit [Integer] max results (default 20, max 100)
    # @return [Array<Bounty>]
    def list_bounties(status: "open", poster: nil, submitter: nil, limit: 20)
      params = ["limit=#{limit}"]
      params << "status=#{status}" if status
      params << "poster=#{poster}" if poster
      params << "submitter=#{submitter}" if submitter
      data = @transport.get("/bounties?#{params.join('&')}")
      items = data.is_a?(Hash) ? (data["data"] || []) : data
      items.map { |d| Bounty.new(d) }
    end

    # ─── Deposits ─────────────────────────────────────────────────────────────

    # Place a security deposit with a provider.
    # @param provider [String] 0x-prefixed provider address
    # @param amount [Numeric] amount in USDC
    # @param expires_in_secs [Integer] expiry duration in seconds (default: 3600)
    # @param permit [PermitSignature, nil] optional EIP-2612 permit for gasless approval
    # @return [Deposit]
    def place_deposit(provider, amount, expires_in_secs: 3600, permit: nil)
      validate_address!(provider)
      validate_amount!(amount)
      body = {
        chain: @chain,
        provider: provider,
        amount: amount.to_f,
        expiry: Time.now.to_i + expires_in_secs
      }
      body[:permit] = permit.to_h if permit
      Deposit.new(@transport.post("/deposits", body))
    end

    # Return a deposit to the payer.
    # @param deposit_id [String]
    # @return [Transaction]
    def return_deposit(deposit_id)
      Transaction.new(@transport.post("/deposits/#{deposit_id}/return", {}))
    end

    # Lock a security deposit.
    # @deprecated Use {#place_deposit} instead
    def lock_deposit(provider, amount, expires_in_secs, permit: nil)
      place_deposit(provider, amount, expires_in_secs: expires_in_secs, permit: permit)
    end

    # ─── Payment Intents ─────────────────────────────────────────────────────

    # Propose a payment intent for counterpart approval before execution.
    # @param to [String] 0x-prefixed address
    # @param amount [Numeric] amount in USDC
    # @param type [String] payment type — "direct", "escrow", "tab"
    # @return [Intent]
    def propose_intent(to, amount, type: "direct")
      validate_address!(to)
      validate_amount!(amount)
      body = { to: to, amount: amount.to_s, type: type }
      Intent.new(@transport.post("/intents", body))
    end

    # ─── Webhooks ─────────────────────────────────────────────────────────────

    # Register a webhook endpoint to receive event notifications.
    # @param url [String] the HTTPS endpoint that will receive POST notifications
    # @param events [Array<String>] event types to subscribe to (e.g. ["payment.sent", "escrow.funded"])
    # @param chains [Array<String>, nil] optional chain names to filter by
    # @return [Webhook]
    def register_webhook(url, events, chains: nil)
      body = { url: url, events: events }
      body[:chains] = chains if chains
      Webhook.new(@transport.post("/webhooks", body))
    end

    # ─── One-time operator links ───────────────────────────────────────────────

    # Generate a one-time URL for the operator to fund this wallet.
    # @return [LinkResponse]
    def create_fund_link
      LinkResponse.new(@transport.post("/links/fund", {}))
    end

    # Generate a one-time URL for the operator to withdraw funds.
    # @return [LinkResponse]
    def create_withdraw_link
      LinkResponse.new(@transport.post("/links/withdraw", {}))
    end

    # ─── Testnet ──────────────────────────────────────────────────────────────

    # Mint testnet USDC. Max $2,500 per call, once per hour per wallet.
    # @param amount [Numeric] amount in USDC
    # @return [Hash] { "tx_hash" => "0x...", "balance" => 1234.56 }
    def mint(amount)
      @transport.post("/mint", { wallet: address, amount: amount })
    end

    private

    ADDRESS_RE = /\A0x[0-9a-fA-F]{40}\z/

    def validate_address!(addr)
      return if addr.match?(ADDRESS_RE)
      raise RemitError.new(
        RemitError::INVALID_ADDRESS,
        "Invalid address #{addr.inspect}: expected 0x-prefixed 40-character hex string. " \
        "Got #{addr.length} characters.",
        context: { address: addr }
      )
    end

    def validate_amount!(amount)
      d = BigDecimal(amount.to_s)
      return if d >= MIN_AMOUNT
      raise RemitError.new(
        RemitError::INVALID_AMOUNT,
        "Amount #{amount} is below the minimum of #{MIN_AMOUNT} USDC.",
        context: { amount: amount.to_s, minimum: MIN_AMOUNT.to_s }
      )
    rescue ArgumentError
      raise RemitError.new(
        RemitError::INVALID_AMOUNT,
        "Invalid amount #{amount.inspect}: must be a numeric value.",
        context: { amount: amount.inspect }
      )
    end

    # ─── EIP-712 helpers (used by sign_tab_charge) ────────────────────────

    def keccak256_raw(data)
      Remitmd::Keccak.digest(data.b)
    end

    def abi_uint256(value)
      [value.to_i.to_s(16).rjust(64, "0")].pack("H*")
    end

    def abi_address(addr)
      hex = addr.to_s.delete_prefix("0x").rjust(64, "0")
      [hex].pack("H*")
    end
  end
end
