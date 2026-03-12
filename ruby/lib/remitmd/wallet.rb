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
    # @param chain [String]            chain name — "base", "base_sepolia", "arbitrum", "optimism"
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
      # The server accepts "base", "arbitrum", "optimism" — not "base_sepolia" etc.
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
    # @return [Transaction]
    def pay(to, amount, memo: nil)
      validate_address!(to)
      validate_amount!(amount)
      nonce = SecureRandom.hex(16)
      body = { to: to, amount: amount.to_s, task: memo || "", chain: @chain, nonce: nonce, signature: "0x" }
      Transaction.new(@transport.post("/payments/direct", body))
    end

    # ─── Escrow ───────────────────────────────────────────────────────────────

    # Create a new escrow (funds held until release or cancel).
    # @param payee [String] 0x-prefixed payee address
    # @param amount [Numeric] amount in USDC
    # @param memo [String, nil] optional note
    # @param expires_in_secs [Integer, nil] optional expiry in seconds from now
    # @return [Escrow]
    def create_escrow(payee, amount, memo: nil, expires_in_secs: nil)
      validate_address!(payee)
      validate_amount!(amount)
      body = { payee: payee, amount: amount.to_s }
      body[:memo] = memo if memo
      body[:expires_in_secs] = expires_in_secs if expires_in_secs
      Escrow.new(@transport.post("/escrows", body))
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

    # Fetch escrow details.
    # @param escrow_id [String]
    # @return [Escrow]
    def get_escrow(escrow_id)
      Escrow.new(@transport.get("/escrows/#{escrow_id}"))
    end

    # ─── Tabs (Metered Billing) ───────────────────────────────────────────────

    # Open a payment tab for off-chain metered billing.
    # @param counterpart [String] 0x-prefixed counterpart address
    # @param limit [Numeric] maximum tab credit in USDC
    # @param closes_in_secs [Integer, nil] optional expiry
    # @return [Tab]
    def create_tab(counterpart, limit, closes_in_secs: nil)
      validate_address!(counterpart)
      validate_amount!(limit)
      body = { counterpart: counterpart, limit: limit.to_s }
      body[:closes_in_secs] = closes_in_secs if closes_in_secs
      Tab.new(@transport.post("/tabs", body))
    end

    # Record a debit against an open tab (off-chain, no gas).
    # @param tab_id [String]
    # @param amount [Numeric] amount in USDC
    # @param memo [String] description of this debit
    # @return [TabDebit]
    def debit_tab(tab_id, amount, memo = "")
      validate_amount!(amount)
      body = { amount: amount.to_s, memo: memo }
      TabDebit.new(@transport.post("/tabs/#{tab_id}/charge", body))
    end

    # Settle a tab on-chain, paying the net balance.
    # @param tab_id [String]
    # @return [Transaction]
    def settle_tab(tab_id)
      Transaction.new(@transport.post("/tabs/#{tab_id}/close", {}))
    end

    # ─── Streams (Payment Streaming) ─────────────────────────────────────────

    # Create a real-time payment stream.
    # @param recipient [String] 0x-prefixed address
    # @param rate_per_sec [Numeric] USDC per second
    # @param deposit [Numeric] upfront deposit in USDC
    # @return [Stream]
    def create_stream(recipient, rate_per_sec, deposit)
      validate_address!(recipient)
      validate_amount!(rate_per_sec)
      validate_amount!(deposit)
      body = { recipient: recipient, rate_per_sec: rate_per_sec.to_s, deposit: deposit.to_s }
      Stream.new(@transport.post("/streams", body))
    end

    # Withdraw accrued funds from a stream.
    # @param stream_id [String]
    # @return [Transaction]
    def withdraw_stream(stream_id)
      Transaction.new(@transport.post("/streams/#{stream_id}/withdraw", {}))
    end

    # ─── Bounties ─────────────────────────────────────────────────────────────

    # Post a bounty for any agent to claim by completing a task.
    # @param award [Numeric] amount in USDC
    # @param description [String] task description
    # @param expires_in_secs [Integer, nil] optional expiry
    # @return [Bounty]
    def create_bounty(award, description, expires_in_secs: nil)
      validate_amount!(award)
      body = { award: award.to_s, description: description }
      body[:expires_in_secs] = expires_in_secs if expires_in_secs
      Bounty.new(@transport.post("/bounties", body))
    end

    # Award a bounty to the winning agent.
    # @param bounty_id [String]
    # @param winner [String] 0x-prefixed address of winner
    # @return [Transaction]
    def award_bounty(bounty_id, winner)
      validate_address!(winner)
      Transaction.new(@transport.post("/bounties/#{bounty_id}/award", { winner: winner }))
    end

    # ─── Deposits ─────────────────────────────────────────────────────────────

    # Lock a security deposit.
    # @param beneficiary [String] 0x-prefixed address
    # @param amount [Numeric] amount in USDC
    # @param lock_secs [Integer] duration to lock in seconds
    # @return [Deposit]
    def lock_deposit(beneficiary, amount, lock_secs)
      validate_address!(beneficiary)
      validate_amount!(amount)
      body = { beneficiary: beneficiary, amount: amount.to_s, lock_secs: lock_secs }
      Deposit.new(@transport.post("/deposits", body))
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
  end
end
