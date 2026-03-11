# frozen_string_literal: true

require "securerandom"
require "time"
require "bigdecimal"
require "bigdecimal/util"

module Remitmd
  # In-memory test double for remit.md. Zero network, zero latency, deterministic.
  #
  # MockRemit gives you a RemitWallet backed by in-memory state so you can test
  # your agent's payment logic without a live API or spending real USDC.
  #
  # @example
  #   mock   = Remitmd::MockRemit.new
  #   wallet = mock.wallet
  #
  #   wallet.pay("0x0000000000000000000000000000000000000001", 1.50)
  #
  #   mock.was_paid?("0x0000000000000000000000000000000000000001", 1.50) # => true
  #   mock.total_paid_to("0x0000000000000000000000000000000000000001")   # => BigDecimal("1.5")
  #   mock.transaction_count                                              # => 1
  class MockRemit
    MOCK_ADDRESS = "0xMockWallet0000000000000000000000000001"
    DEFAULT_BALANCE = BigDecimal("10000")

    def initialize(balance: DEFAULT_BALANCE)
      @mutex    = Mutex.new
      @state    = initial_state(BigDecimal(balance.to_s))
    end

    # Return a RemitWallet backed by this mock. No private key required.
    def wallet
      RemitWallet.new(signer: MockSigner.new(MOCK_ADDRESS), transport: MockTransport.new(@state, @mutex))
    end

    # Reset all state. Call between test cases to prevent state leakage.
    def reset
      @mutex.synchronize { @state.replace(initial_state(DEFAULT_BALANCE)) }
    end

    # Override the simulated USDC balance.
    def set_balance(amount)
      @mutex.synchronize { @state[:balance] = BigDecimal(amount.to_s) }
    end

    # Current mock balance.
    def balance
      @mutex.synchronize { @state[:balance] }
    end

    # All transactions recorded.
    def transactions
      @mutex.synchronize { @state[:transactions].dup }
    end

    # Total number of transactions recorded.
    def transaction_count
      @mutex.synchronize { @state[:transactions].length }
    end

    # True if a payment of exactly +amount+ USDC was sent to +recipient+.
    def was_paid?(recipient, amount)
      d = BigDecimal(amount.to_s)
      @mutex.synchronize do
        @state[:transactions].any? do |tx|
          tx.to.casecmp(recipient).zero? && tx.amount == d
        end
      end
    end

    # Sum of all USDC sent to +recipient+.
    def total_paid_to(recipient)
      @mutex.synchronize do
        @state[:transactions]
          .select { |tx| tx.to.casecmp(recipient).zero? }
          .sum(BigDecimal("0"), &:amount)
      end
    end

    private

    def initial_state(balance)
      {
        balance:      balance,
        transactions: [],
        escrows:      {},
        tabs:         {},
        streams:      {},
        bounties:     {},
        deposits:     {},
      }
    end
  end

  # ─── Internal: MockSigner ──────────────────────────────────────────────────

  class MockSigner
    include Signer

    def initialize(addr)
      @address = addr
    end

    attr_reader :address

    def sign(_message)
      "0x" + SecureRandom.hex(32)
    end
  end

  # ─── Internal: MockTransport ───────────────────────────────────────────────

  class MockTransport
    def initialize(state, mutex)
      @state = state
      @mutex = mutex
    end

    def get(path)
      dispatch("GET", path, nil)
    end

    def post(path, body = nil)
      dispatch("POST", path, body)
    end

    private

    def dispatch(method, path, body)
      @mutex.synchronize { handle(method, path, body || {}) }
    end

    def handle(method, path, b)
      case [method, path]

      # Balance
      in ["GET", "/wallet/balance"]
        {
          "usdc"       => @state[:balance].to_s("F"),
          "address"    => MockRemit::MOCK_ADDRESS,
          "chain_id"   => ChainId::BASE_SEPOLIA,
          "updated_at" => now,
        }

      # Direct payment
      in ["POST", "/payments/direct"]
        to     = fetch!(b, :to)
        amount = decimal!(b, :amount)
        check_balance!(amount)
        @state[:balance] -= amount
        tx = make_tx(to: to, amount: amount, memo: b[:memo].to_s)
        @state[:transactions] << tx
        tx_hash(tx)

      # Escrow create
      in ["POST", "/escrows"]
        payee  = fetch!(b, :payee)
        amount = decimal!(b, :amount)
        check_balance!(amount)
        @state[:balance] -= amount
        esc = make_escrow(payee: payee, amount: amount, memo: b[:memo].to_s)
        @state[:escrows][esc.id] = esc
        escrow_hash(esc)

      # Escrow release
      in ["POST", path] if path.end_with?("/release") && path.include?("/escrows/")
        id  = extract_id(path, "/escrows/", "/release")
        esc = @state[:escrows].fetch(id) { raise not_found(RemitError::ESCROW_NOT_FOUND, id) }
        new_esc = update_escrow(esc, status: EscrowStatus::RELEASED)
        @state[:escrows][id] = new_esc
        tx = make_tx(from: esc.payer, to: esc.payee, amount: esc.amount)
        @state[:transactions] << tx
        tx_hash(tx)

      # Escrow cancel
      in ["POST", path] if path.end_with?("/cancel") && path.include?("/escrows/")
        id  = extract_id(path, "/escrows/", "/cancel")
        esc = @state[:escrows].fetch(id) { raise not_found(RemitError::ESCROW_NOT_FOUND, id) }
        new_esc = update_escrow(esc, status: EscrowStatus::CANCELLED)
        @state[:escrows][id] = new_esc
        @state[:balance] += esc.amount
        tx = make_tx(from: esc.payer, to: esc.payer, amount: esc.amount, memo: "escrow cancelled")
        @state[:transactions] << tx
        tx_hash(tx)

      # Escrow get
      in ["GET", path] if path.start_with?("/escrows/")
        id  = path.delete_prefix("/escrows/")
        esc = @state[:escrows].fetch(id) { raise not_found(RemitError::ESCROW_NOT_FOUND, id) }
        escrow_hash(esc)

      # Tab create
      in ["POST", "/tabs"]
        counterpart = fetch!(b, :counterpart)
        limit       = decimal!(b, :limit)
        tab = make_tab(counterpart: counterpart, limit: limit)
        @state[:tabs][tab.id] = tab
        tab_hash(tab)

      # Tab charge (debit)
      in ["POST", path] if path.end_with?("/charge") && path.include?("/tabs/")
        id     = extract_id(path, "/tabs/", "/charge")
        amount = decimal!(b, :amount)
        tab    = @state[:tabs].fetch(id) { raise not_found(RemitError::TAB_NOT_FOUND, id) }
        new_tab = update_tab(tab, used: tab.used + amount, remaining: tab.remaining - amount)
        @state[:tabs][id] = new_tab
        {
          "tab_id"    => id,
          "amount"    => amount.to_s("F"),
          "memo"      => b[:memo].to_s,
          "sequence"  => 1,
          "signature" => "0x00",
        }

      # Tab close (settle)
      in ["POST", path] if path.end_with?("/close") && path.include?("/tabs/")
        id  = extract_id(path, "/tabs/", "/close")
        tab = @state[:tabs].fetch(id) { raise not_found(RemitError::TAB_NOT_FOUND, id) }
        new_tab = update_tab(tab, status: TabStatus::SETTLED)
        @state[:tabs][id] = new_tab
        tx = make_tx(from: tab.opener, to: tab.counterpart, amount: tab.used, memo: "tab settlement")
        @state[:transactions] << tx
        tx_hash(tx)

      # Stream create
      in ["POST", "/streams"]
        recipient = fetch!(b, :recipient)
        rate_per_sec = decimal!(b, :rate_per_sec)
        deposit = decimal!(b, :deposit)
        check_balance!(deposit)
        @state[:balance] -= deposit
        s = make_stream(recipient: recipient, rate_per_sec: rate_per_sec, deposited: deposit)
        @state[:streams][s.id] = s
        stream_hash(s)

      # Stream withdraw
      in ["POST", path] if path.end_with?("/withdraw") && path.include?("/streams/")
        id  = extract_id(path, "/streams/", "/withdraw")
        s   = @state[:streams].fetch(id) { raise not_found(RemitError::STREAM_NOT_FOUND, id) }
        tx  = make_tx(from: s.sender, to: s.recipient, amount: s.deposited, memo: "stream withdraw")
        @state[:transactions] << tx
        tx_hash(tx)

      # Bounty create
      in ["POST", "/bounties"]
        award       = decimal!(b, :award)
        description = fetch!(b, :description)
        check_balance!(award)
        @state[:balance] -= award
        bnt = make_bounty(award: award, description: description)
        @state[:bounties][bnt.id] = bnt
        bounty_hash(bnt)

      # Bounty award
      in ["POST", path] if path.end_with?("/award") && path.include?("/bounties/")
        id     = extract_id(path, "/bounties/", "/award")
        winner = fetch!(b, :winner)
        bnt    = @state[:bounties].fetch(id) { raise not_found(RemitError::BOUNTY_NOT_FOUND, id) }
        new_bnt = update_bounty(bnt, status: BountyStatus::AWARDED, winner: winner)
        @state[:bounties][id] = new_bnt
        tx = make_tx(from: bnt.poster, to: winner, amount: bnt.award, memo: "bounty award")
        @state[:transactions] << tx
        tx_hash(tx)

      # Deposit create
      in ["POST", "/deposits"]
        beneficiary = fetch!(b, :beneficiary)
        amount      = decimal!(b, :amount)
        check_balance!(amount)
        @state[:balance] -= amount
        dep = make_deposit(beneficiary: beneficiary, amount: amount)
        @state[:deposits][dep.id] = dep
        deposit_hash(dep)

      # Reputation
      in ["GET", path] if path.start_with?("/reputation/")
        addr = path.delete_prefix("/reputation/")
        {
          "address"           => addr,
          "score"             => 750,
          "total_paid"        => "1000.0",
          "total_received"    => "500.0",
          "transaction_count" => 42,
          "dispute_rate"      => 0.0,
          "member_since"      => now,
        }

      # Spending summary
      in ["GET", "/wallet/spending"]
        total = @state[:transactions].sum(BigDecimal("0"), &:amount)
        count = @state[:transactions].length
        {
          "address"        => MockRemit::MOCK_ADDRESS,
          "period"         => "month",
          "total_spent"    => total.to_s("F"),
          "total_fees"     => (BigDecimal("0.001") * count).to_s("F"),
          "tx_count"       => count,
          "top_recipients" => [],
        }

      # Budget
      in ["GET", "/wallet/budget"]
        {
          "daily_limit"       => "10000.0",
          "daily_used"        => "0.0",
          "daily_remaining"   => "10000.0",
          "monthly_limit"     => "100000.0",
          "monthly_used"      => "0.0",
          "monthly_remaining" => "100000.0",
          "per_tx_limit"      => "1000.0",
        }

      # History
      in ["GET", path] if path.start_with?("/wallet/history")
        txs = @state[:transactions]
        {
          "items"    => txs.map { |tx| tx_hash(tx) },
          "total"    => txs.length,
          "page"     => 1,
          "per_page" => 50,
          "has_more" => false,
        }

      # Intents
      in ["POST", "/intents"]
        to     = fetch!(b, :to)
        amount = decimal!(b, :amount)
        {
          "id"         => new_id("int"),
          "from"       => MockRemit::MOCK_ADDRESS,
          "to"         => to,
          "amount"     => amount.to_s("F"),
          "type"       => b[:type] || "direct",
          "expires_at" => now,
          "created_at" => now,
        }

      else
        {}
      end
    end

    # ─── Builder helpers ────────────────────────────────────────────────────

    def make_tx(to:, amount:, from: MockRemit::MOCK_ADDRESS, memo: "")
      Transaction.new(
        "id"           => new_id("tx"),
        "tx_hash"      => "0x#{SecureRandom.hex(32)}",
        "from"         => from,
        "to"           => to,
        "amount"       => amount.to_s("F"),
        "fee"          => "0.001",
        "memo"         => memo,
        "chain_id"     => ChainId::BASE_SEPOLIA,
        "block_number" => 0,
        "created_at"   => now,
      )
    end

    def make_escrow(payee:, amount:, memo: "")
      Escrow.new(
        "id"         => new_id("esc"),
        "payer"      => MockRemit::MOCK_ADDRESS,
        "payee"      => payee,
        "amount"     => amount.to_s("F"),
        "fee"        => "0.001",
        "status"     => EscrowStatus::FUNDED,
        "memo"       => memo,
        "milestones" => [],
        "splits"     => [],
        "created_at" => now,
      )
    end

    def make_tab(counterpart:, limit:)
      Tab.new(
        "id"          => new_id("tab"),
        "opener"      => MockRemit::MOCK_ADDRESS,
        "counterpart" => counterpart,
        "limit"       => limit.to_s("F"),
        "used"        => "0",
        "remaining"   => limit.to_s("F"),
        "status"      => TabStatus::OPEN,
        "created_at"  => now,
      )
    end

    def make_stream(recipient:, rate_per_sec:, deposited:)
      Stream.new(
        "id"           => new_id("str"),
        "sender"       => MockRemit::MOCK_ADDRESS,
        "recipient"    => recipient,
        "rate_per_sec" => rate_per_sec.to_s("F"),
        "deposited"    => deposited.to_s("F"),
        "withdrawn"    => "0",
        "status"       => StreamStatus::ACTIVE,
        "started_at"   => now,
      )
    end

    def make_bounty(award:, description:)
      Bounty.new(
        "id"          => new_id("bnt"),
        "poster"      => MockRemit::MOCK_ADDRESS,
        "award"       => award.to_s("F"),
        "description" => description,
        "status"      => BountyStatus::OPEN,
        "winner"      => "",
        "created_at"  => now,
      )
    end

    def make_deposit(beneficiary:, amount:)
      Deposit.new(
        "id"          => new_id("dep"),
        "depositor"   => MockRemit::MOCK_ADDRESS,
        "beneficiary" => beneficiary,
        "amount"      => amount.to_s("F"),
        "status"      => DepositStatus::LOCKED,
        "created_at"  => now,
      )
    end

    def update_escrow(esc, **changes)
      h = escrow_hash(esc).merge(changes.transform_keys(&:to_s))
      Escrow.new(h)
    end

    def update_tab(tab, **changes)
      h = tab_hash(tab).merge(changes.transform_keys(&:to_s))
      Tab.new(h)
    end

    def update_bounty(bnt, **changes)
      h = bounty_hash(bnt).merge(changes.transform_keys(&:to_s))
      Bounty.new(h)
    end

    def tx_hash(tx)
      {
        "id"           => tx.id,
        "tx_hash"      => tx.tx_hash,
        "from"         => tx.from,
        "to"           => tx.to,
        "amount"       => tx.amount.to_s("F"),
        "fee"          => tx.fee.to_s("F"),
        "memo"         => tx.memo,
        "chain_id"     => tx.chain_id,
        "block_number" => tx.block_number,
        "created_at"   => now,
      }
    end

    def escrow_hash(esc)
      {
        "id"         => esc.id,
        "payer"      => esc.payer,
        "payee"      => esc.payee,
        "amount"     => esc.amount.to_s("F"),
        "fee"        => esc.fee.to_s("F"),
        "status"     => esc.status,
        "memo"       => esc.memo,
        "milestones" => esc.milestones,
        "splits"     => esc.splits,
        "expires_at" => esc.expires_at&.iso8601,
        "created_at" => now,
      }
    end

    def tab_hash(tab)
      {
        "id"          => tab.id,
        "opener"      => tab.opener,
        "counterpart" => tab.counterpart,
        "limit"       => tab.limit.to_s("F"),
        "used"        => tab.used.to_s("F"),
        "remaining"   => tab.remaining.to_s("F"),
        "status"      => tab.status,
        "created_at"  => now,
      }
    end

    def stream_hash(s)
      {
        "id"           => s.id,
        "sender"       => s.sender,
        "recipient"    => s.recipient,
        "rate_per_sec" => s.rate_per_sec.to_s("F"),
        "deposited"    => s.deposited.to_s("F"),
        "withdrawn"    => s.withdrawn.to_s("F"),
        "status"       => s.status,
        "started_at"   => now,
      }
    end

    def bounty_hash(bnt)
      {
        "id"          => bnt.id,
        "poster"      => bnt.poster,
        "award"       => bnt.award.to_s("F"),
        "description" => bnt.description,
        "status"      => bnt.status,
        "winner"      => bnt.winner,
        "expires_at"  => bnt.expires_at&.iso8601,
        "created_at"  => now,
      }
    end

    def deposit_hash(dep)
      {
        "id"          => dep.id,
        "depositor"   => dep.depositor,
        "beneficiary" => dep.beneficiary,
        "amount"      => dep.amount.to_s("F"),
        "status"      => dep.status,
        "expires_at"  => dep.expires_at&.iso8601,
        "created_at"  => now,
      }
    end

    # ─── Utilities ──────────────────────────────────────────────────────────

    def new_id(prefix)
      "#{prefix}_#{SecureRandom.hex(4)}"
    end

    def now
      Time.now.utc.iso8601
    end

    def fetch!(h, key)
      val = h[key] || h[key.to_s]
      raise RemitError.new(RemitError::SERVER_ERROR, "Missing field: #{key}") if val.nil?

      val.to_s
    end

    def decimal!(h, key)
      s = fetch!(h, key)
      BigDecimal(s)
    rescue ArgumentError
      raise RemitError.new(RemitError::INVALID_AMOUNT, "Invalid decimal for #{key}: #{s.inspect}")
    end

    def check_balance!(amount)
      bal = @state[:balance]
      return if bal >= amount
      raise RemitError.new(
        RemitError::INSUFFICIENT_FUNDS,
        "Insufficient balance: have #{bal.to_s("F")} USDC, need #{amount.to_s("F")} USDC",
        context: { balance: bal.to_s("F"), amount: amount.to_s("F") }
      )
    end

    def extract_id(path, prefix, suffix)
      path.delete_prefix(prefix).delete_suffix(suffix)
    end

    def not_found(code, id)
      RemitError.new(code, "#{code}: #{id} not found")
    end
  end
end
