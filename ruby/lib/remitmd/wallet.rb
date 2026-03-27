# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"
require "json"

module Remitmd
  # Known USDC contract addresses per chain (EIP-2612 compatible).
  USDC_ADDRESSES = {
    "base-sepolia" => "0x2d846325766921935f37d5b4478196d3ef93707c",
    "base" => "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    "localhost" => "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  }.freeze

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
        @chain_key = "base-sepolia"
        @chain_id  = ChainId::BASE_SEPOLIA
        @mock_mode = true
        return
      end

      if private_key.nil? && signer.nil?
        raise ArgumentError, "Provide either :private_key or :signer"
      end
      if !private_key.nil? && !signer.nil?
        raise ArgumentError, "Provide :private_key OR :signer, not both"
      end

      @signer = signer || PrivateKeySigner.new(private_key)
      # Normalize chain key (underscore → hyphen). Full chain name is sent in API bodies.
      @chain_key = chain.tr("_", "-")
      cfg = CHAIN_CONFIG.fetch(chain) do
        raise ArgumentError, "Unknown chain: #{chain}. Valid: #{CHAIN_CONFIG.keys.join(", ")}"
      end
      base_url       = api_url || cfg[:url]
      @chain_id      = cfg[:chain_id]
      router_address ||= ""
      @transport = HttpTransport.new(
        base_url:       base_url,
        signer:         @signer,
        chain_id:       @chain_id,
        router_address: router_address
      )
    end

    # Build a RemitWallet from environment variables.
    # Reads: REMIT_SIGNER_URL + REMIT_SIGNER_TOKEN (preferred, uses HttpSigner),
    # or REMITMD_KEY (primary) / REMITMD_PRIVATE_KEY (deprecated fallback).
    # Also reads: REMITMD_CHAIN, REMITMD_API_URL, REMITMD_ROUTER_ADDRESS.
    def self.from_env
      chain          = ENV.fetch("REMITMD_CHAIN", "base")
      api_url        = ENV["REMITMD_API_URL"]
      router_address = ENV["REMITMD_ROUTER_ADDRESS"]

      # Priority 1: HTTP signer server
      signer_url = ENV["REMIT_SIGNER_URL"]
      if signer_url
        signer_token = ENV["REMIT_SIGNER_TOKEN"]
        raise ArgumentError, "REMIT_SIGNER_TOKEN must be set when REMIT_SIGNER_URL is set" unless signer_token

        signer = HttpSigner.new(url: signer_url, token: signer_token)
        return new(signer: signer, chain: chain, api_url: api_url, router_address: router_address)
      end

      # Priority 2: raw private key
      key = ENV["REMITMD_KEY"] || ENV["REMITMD_PRIVATE_KEY"]
      if ENV["REMITMD_PRIVATE_KEY"] && !ENV["REMITMD_KEY"]
        warn "[remitmd] REMITMD_PRIVATE_KEY is deprecated, use REMITMD_KEY instead"
      end
      raise ArgumentError, "REMITMD_KEY not set (or set REMIT_SIGNER_URL + REMIT_SIGNER_TOKEN)" unless key

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
      @get_contracts ||= ContractAddresses.new(@transport.get("/contracts"))
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
    # @param permit [PermitSignature, nil] EIP-2612 permit — auto-signed if nil
    # @return [Transaction]
    def pay(to, amount, memo: nil, permit: nil)
      validate_address!(to)
      validate_amount!(amount)
      resolved = permit || auto_permit("router", amount.to_f)
      nonce = SecureRandom.hex(16)
      body = { to: to, amount: amount.to_f, task: memo || "", chain: @chain_key, nonce: nonce, signature: "0x" }
      body[:permit] = resolved&.to_h
      Transaction.new(@transport.post("/payments/direct", body))
    end

    # ─── Escrow ───────────────────────────────────────────────────────────────

    # Create a new escrow (funds held until release or cancel).
    # @param payee [String] 0x-prefixed payee address
    # @param amount [Numeric] amount in USDC
    # @param memo [String, nil] optional note
    # @param expires_in_secs [Integer, nil] optional expiry in seconds from now
    # @param permit [PermitSignature, nil] EIP-2612 permit — auto-signed if nil
    # @return [Escrow]
    def create_escrow(payee, amount, memo: nil, expires_in_secs: nil, permit: nil)
      validate_address!(payee)
      validate_amount!(amount)
      resolved = permit || auto_permit("escrow", amount.to_f)

      # Step 1: create invoice on server.
      invoice_id = SecureRandom.hex(16)
      nonce      = SecureRandom.hex(16)
      inv_body = {
        id: invoice_id, chain: @chain_key,
        from_agent: address.downcase, to_agent: payee.downcase,
        amount: amount.to_f, type: "escrow",
        task: memo || "", nonce: nonce, signature: "0x"
      }
      inv_body[:escrow_timeout] = expires_in_secs if expires_in_secs
      @transport.post("/invoices", inv_body)

      # Step 2: fund the escrow.
      esc_body = { invoice_id: invoice_id, permit: resolved&.to_h }
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
    # @param permit [PermitSignature, nil] EIP-2612 permit — auto-signed if nil
    # @return [Tab]
    def create_tab(provider, limit_amount, per_unit = 0.0, expires_in_secs: 86_400, permit: nil)
      validate_address!(provider)
      validate_amount!(limit_amount)
      resolved = permit || auto_permit("tab", limit_amount.to_f)
      body = {
        chain: @chain_key,
        provider: provider,
        limit_amount: limit_amount.to_f,
        per_unit: per_unit.to_f,
        expiry: Time.now.to_i + expires_in_secs,
        permit: resolved&.to_h
      }
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
      body = {
        final_amount: final_amount ? final_amount.to_f : 0,
        provider_sig: provider_sig || "0x"
      }
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

    # ─── EIP-2612 Permit ─────────────────────────────────────────────────────

    # Sign an EIP-2612 permit for USDC approval.
    # Domain: name="USD Coin", version="2", chainId, verifyingContract=USDC address
    # Type: Permit(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
    # @param spender [String] contract address that will be approved
    # @param value [Integer] amount in USDC base units (6 decimals)
    # @param deadline [Integer] permit deadline (Unix timestamp)
    # @param nonce [Integer] current permit nonce for this wallet
    # @param usdc_address [String, nil] override the USDC contract address
    # @return [PermitSignature]
    def sign_usdc_permit(spender, value, deadline, nonce = 0, usdc_address: nil)
      usdc_addr = usdc_address || USDC_ADDRESSES[@chain_key]
      if usdc_addr.nil? || usdc_addr.empty?
        raise RemitError.new(
          RemitError::INVALID_ADDRESS,
          "No USDC address configured for chain #{@chain_key.inspect}. " \
          "Valid chains: #{USDC_ADDRESSES.keys.join(", ")}",
          context: { chain: @chain_key }
        )
      end
      chain_id = @chain_id || ChainId::BASE_SEPOLIA

      # Domain separator for USDC (EIP-2612)
      domain_type_hash = keccak256_raw(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
      )
      name_hash = keccak256_raw("USD Coin")
      version_hash = keccak256_raw("2")
      chain_id_enc = abi_uint256(chain_id)
      contract_enc = abi_address(usdc_addr)

      domain_data = domain_type_hash + name_hash + version_hash + chain_id_enc + contract_enc
      domain_sep = keccak256_raw(domain_data)

      # Permit struct hash
      type_hash = keccak256_raw(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
      )
      owner_enc    = abi_address(address)
      spender_enc  = abi_address(spender)
      value_enc    = abi_uint256(value)
      nonce_enc    = abi_uint256(nonce)
      deadline_enc = abi_uint256(deadline)

      struct_data = type_hash + owner_enc + spender_enc + value_enc + nonce_enc + deadline_enc
      struct_hash = keccak256_raw(struct_data)

      # EIP-712 digest
      digest = keccak256_raw("\x19\x01".b + domain_sep + struct_hash)
      sig_hex = @signer.sign(digest)

      # Parse r, s, v from the 65-byte signature
      sig_bytes = sig_hex.delete_prefix("0x")
      r = "0x#{sig_bytes[0, 64]}"
      s = "0x#{sig_bytes[64, 64]}"
      v = sig_bytes[128, 2].to_i(16)

      PermitSignature.new(value: value, deadline: deadline, v: v, r: r, s: s)
    end

    # Convenience: sign a USDC permit. Auto-fetches nonce, defaults deadline to 1 hour.
    # @param spender [String] contract address to approve (e.g. router, escrow)
    # @param amount [Numeric] amount in USDC (e.g. 5.0 for $5.00)
    # @param deadline [Integer, nil] optional Unix timestamp; defaults to 1 hour from now
    # @return [PermitSignature]
    def sign_permit(spender, amount, deadline: nil)
      usdc_addr = USDC_ADDRESSES[@chain_key]
      if usdc_addr.nil? || usdc_addr.empty?
        raise RemitError.new(
          RemitError::INVALID_ADDRESS,
          "No USDC address configured for chain #{@chain_key.inspect}. " \
          "Valid chains: #{USDC_ADDRESSES.keys.join(", ")}",
          context: { chain: @chain_key }
        )
      end
      nonce = fetch_permit_nonce(usdc_addr)
      dl = deadline || (Time.now.to_i + 3600)
      raw = (amount * 1_000_000).round.to_i
      sign_usdc_permit(spender, raw, dl, nonce, usdc_address: usdc_addr)
    end

    # ─── Streams (Payment Streaming) ─────────────────────────────────────────

    # Create a real-time payment stream.
    # @param payee [String] 0x-prefixed address of the stream recipient
    # @param rate_per_second [Numeric] USDC per second
    # @param max_total [Numeric] maximum total USDC for the stream
    # @param permit [PermitSignature, nil] EIP-2612 permit — auto-signed if nil
    # @return [Stream]
    def create_stream(payee, rate_per_second, max_total, permit: nil)
      validate_address!(payee)
      validate_amount!(rate_per_second)
      validate_amount!(max_total)
      resolved = permit || auto_permit("stream", max_total.to_f)
      body = {
        chain: @chain_key,
        payee: payee,
        rate_per_second: rate_per_second.to_s,
        max_total: max_total.to_s,
        permit: resolved&.to_h
      }
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
    # @param permit [PermitSignature, nil] EIP-2612 permit — auto-signed if nil
    # @return [Bounty]
    def create_bounty(amount, task_description, deadline, max_attempts: 10, permit: nil)
      validate_amount!(amount)
      resolved = permit || auto_permit("bounty", amount.to_f)
      body = {
        chain: @chain_key,
        amount: amount.to_f,
        task_description: task_description,
        deadline: deadline,
        max_attempts: max_attempts,
        permit: resolved&.to_h
      }
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
    # @param permit [PermitSignature, nil] EIP-2612 permit — auto-signed if nil
    # @return [Deposit]
    def place_deposit(provider, amount, expires_in_secs: 3600, permit: nil)
      validate_address!(provider)
      validate_amount!(amount)
      resolved = permit || auto_permit("deposit", amount.to_f)
      body = {
        chain: @chain_key,
        provider: provider,
        amount: amount.to_f,
        expiry: Time.now.to_i + expires_in_secs,
        permit: resolved&.to_h
      }
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
      body[:chains] = chains || [@chain_key]
      Webhook.new(@transport.post("/webhooks", body))
    end

    # ─── One-time operator links ───────────────────────────────────────────────

    # Generate a one-time URL for the operator to fund this wallet.
    # @param messages [Array<Hash>, nil] chat-style messages (each with :role and :text)
    # @param agent_name [String, nil] agent display name shown on the funding page
    # @param permit [PermitSignature, nil] EIP-2612 permit — auto-signed if nil
    # @return [LinkResponse]
    def create_fund_link(messages: nil, agent_name: nil, permit: nil)
      body = {}
      body[:messages] = messages if messages
      body[:agent_name] = agent_name if agent_name
      begin
        resolved = permit || auto_permit("relayer", 999_999_999.0)
        body[:permit] = resolved&.to_h
      rescue StandardError => e
        warn "[remitmd] create_fund_link: auto-permit failed: #{e.message}"
      end
      LinkResponse.new(@transport.post("/links/fund", body))
    end

    # Generate a one-time URL for the operator to withdraw funds.
    # @param messages [Array<Hash>, nil] chat-style messages (each with :role and :text)
    # @param agent_name [String, nil] agent display name shown on the withdraw page
    # @param permit [PermitSignature, nil] EIP-2612 permit — auto-signed if nil
    # @return [LinkResponse]
    def create_withdraw_link(messages: nil, agent_name: nil, permit: nil)
      body = {}
      body[:messages] = messages if messages
      body[:agent_name] = agent_name if agent_name
      begin
        resolved = permit || auto_permit("relayer", 999_999_999.0)
        body[:permit] = resolved&.to_h
      rescue StandardError => e
        warn "[remitmd] create_withdraw_link: auto-permit failed: #{e.message}"
      end
      LinkResponse.new(@transport.post("/links/withdraw", body))
    end

    # ─── Testnet ──────────────────────────────────────────────────────────────

    # Mint testnet USDC. Max $2,500 per call, once per hour per wallet.
    # Uses unauthenticated HTTP (no EIP-712 auth headers).
    # @param amount [Numeric] amount in USDC
    # @return [Hash] { "tx_hash" => "0x...", "balance" => 1234.56 }
    def mint(amount)
      if @mock_mode
        @transport.post("/mint", { wallet: address, amount: amount })
      else
        cfg = CHAIN_CONFIG[@chain_key]
        base_url = cfg ? cfg[:url] : "https://testnet.remit.md/api/v1"
        uri = URI("#{base_url}/mint")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.read_timeout = 15
        req = Net::HTTP::Post.new(uri.path)
        req["Content-Type"] = "application/json"
        req.body = { wallet: address, amount: amount }.to_json
        resp = http.request(req)
        JSON.parse(resp.body.to_s)
      end
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

    # ─── EIP-712 helpers (used by sign_tab_charge / sign_usdc_permit) ─────

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

    # ─── Permit helpers ──────────────────────────────────────────────────

    # Fetch the EIP-2612 permit nonce from the API.
    # @param usdc_address [String] the USDC contract address
    # @return [Integer] current nonce
    def fetch_permit_nonce(_usdc_address)
      return 0 if @mock_mode

      data = @transport.get("/status/#{address}")
      nonce = data.is_a?(Hash) ? data["permit_nonce"] : nil
      if nonce.nil?
        raise RemitError.new(
          RemitError::NETWORK_ERROR,
          "permit_nonce not available from API for #{address}. " \
          "Ensure the server supports the permit_nonce field in GET /api/v1/status.",
          context: { address: address }
        )
      end
      nonce.to_i
    end

    # Auto-sign a permit for the given contract type and amount.
    # Returns nil on failure instead of raising, so callers can proceed without a permit.
    # @param contract [String] contract key — "router", "escrow", "tab", etc.
    # @param amount [Numeric] amount in USDC
    # @return [PermitSignature, nil]
    def auto_permit(contract, amount)
      contracts = get_contracts
      spender = contracts.send(contract.to_sym)
      return nil unless spender

      sign_permit(spender, amount)
    rescue => e
      warn "[remitmd] auto-permit failed for #{contract} (amount=#{amount}): #{e.message}"
      nil
    end

    # Spender contract mapping for auto_permit.
    PERMIT_SPENDER = {
      pay:                  :router,
      create_escrow:        :escrow,
      create_tab:           :tab,
      create_stream:        :stream,
      create_bounty:        :bounty,
      place_deposit:        :deposit,
      create_fund_link:     :relayer,
      create_withdraw_link: :relayer,
    }.freeze
  end
end
