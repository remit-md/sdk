# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"
require "time"

module Remitmd
  # Supported chain IDs
  module ChainId
    BASE         = 8453
    BASE_SEPOLIA = 84532
    ARBITRUM     = 42161
    OPTIMISM     = 10
  end

  # ─── Status types ─────────────────────────────────────────────────────────

  module EscrowStatus
    PENDING   = "pending"
    FUNDED    = "funded"
    RELEASED  = "released"
    CANCELLED = "cancelled"
    EXPIRED   = "expired"
  end

  module TabStatus
    OPEN    = "open"
    CLOSED  = "closed"
    SETTLED = "settled"
  end

  module StreamStatus
    ACTIVE    = "active"
    PAUSED    = "paused"
    ENDED     = "ended"
    CANCELLED = "cancelled"
  end

  module BountyStatus
    OPEN      = "open"
    AWARDED   = "awarded"
    EXPIRED   = "expired"
    RECLAIMED = "reclaimed"
  end

  module DepositStatus
    LOCKED    = "locked"
    RETURNED  = "returned"
    FORFEITED = "forfeited"
  end

  # ─── Value objects ────────────────────────────────────────────────────────

  # Immutable model base. Builds from a hash with string or symbol keys.
  class Model
    def initialize(attrs)
      attrs.each do |k, v|
        instance_variable_set("@#{k}", v)
        self.class.attr_reader(k.to_sym) unless respond_to?(k.to_sym)
      end
    end

    def to_h
      instance_variables.each_with_object({}) do |var, h|
        h[var.to_s.delete("@").to_sym] = instance_variable_get(var)
      end
    end

    def inspect
      "#<#{self.class.name} #{to_h}>"
    end

    protected

    def decimal(value)
      return value if value.is_a?(BigDecimal)
      return BigDecimal(value.to_s) if value
      nil
    end

    def parse_time(value)
      return value if value.is_a?(Time)
      return Time.parse(value) if value.is_a?(String)
      nil
    end
  end

  class Transaction < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @id           = h["id"]
      @tx_hash      = h["tx_hash"]
      @from         = h["from"]
      @to           = h["to"]
      @amount       = decimal(h["amount"])
      @fee          = decimal(h["fee"] || "0")
      @memo         = h["memo"] || ""
      @chain_id     = h["chain_id"]&.to_i
      @block_number = h["block_number"]&.to_i || 0
      @created_at   = parse_time(h["created_at"])
    end

    attr_reader :id, :tx_hash, :from, :to, :amount, :fee, :memo,
                :chain_id, :block_number, :created_at

    private :decimal, :parse_time
  end

  class Balance < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @usdc       = decimal(h["usdc"])
      @address    = h["address"]
      @chain_id   = h["chain_id"]&.to_i
      @updated_at = parse_time(h["updated_at"])
    end

    attr_reader :usdc, :address, :chain_id, :updated_at

    private :decimal, :parse_time
  end

  class Reputation < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @address           = h["address"]
      @score             = h["score"]&.to_i || 0
      @total_paid        = decimal(h["total_paid"])
      @total_received    = decimal(h["total_received"])
      @transaction_count = h["transaction_count"]&.to_i || 0
      @member_since      = parse_time(h["member_since"])
    end

    attr_reader :address, :score, :total_paid, :total_received,
                :transaction_count, :member_since

    private :decimal, :parse_time
  end

  class Escrow < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @id         = h["id"]
      @payer      = h["payer"]
      @payee      = h["payee"]
      @amount     = decimal(h["amount"])
      @fee        = decimal(h["fee"] || "0")
      @status     = h["status"]
      @memo       = h["memo"] || ""
      @milestones = h["milestones"] || []
      @splits     = h["splits"] || []
      @expires_at = parse_time(h["expires_at"])
      @created_at = parse_time(h["created_at"])
    end

    attr_reader :id, :payer, :payee, :amount, :fee, :status,
                :memo, :milestones, :splits, :expires_at, :created_at

    private :decimal, :parse_time
  end

  class Tab < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @id          = h["id"]
      @opener      = h["opener"]
      @counterpart = h["counterpart"]
      @limit       = decimal(h["limit"])
      @used        = decimal(h["used"] || "0")
      @remaining   = decimal(h["remaining"] || h["limit"])
      @status      = h["status"]
      @created_at  = parse_time(h["created_at"])
      @closes_at   = parse_time(h["closes_at"])
    end

    attr_reader :id, :opener, :counterpart, :limit, :used, :remaining,
                :status, :created_at, :closes_at

    private :decimal, :parse_time
  end

  class TabDebit < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @tab_id    = h["tab_id"]
      @amount    = decimal(h["amount"])
      @memo      = h["memo"] || ""
      @sequence  = h["sequence"]&.to_i || 0
      @signature = h["signature"]
    end

    attr_reader :tab_id, :amount, :memo, :sequence, :signature

    private :decimal
  end

  class Stream < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @id           = h["id"]
      @sender       = h["sender"]
      @recipient    = h["recipient"]
      @rate_per_sec = decimal(h["rate_per_sec"])
      @deposited    = decimal(h["deposited"])
      @withdrawn    = decimal(h["withdrawn"] || "0")
      @status       = h["status"]
      @started_at   = parse_time(h["started_at"])
      @ends_at      = parse_time(h["ends_at"])
    end

    attr_reader :id, :sender, :recipient, :rate_per_sec, :deposited,
                :withdrawn, :status, :started_at, :ends_at

    private :decimal, :parse_time
  end

  class Bounty < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @id          = h["id"]
      @poster      = h["poster"]
      @award       = decimal(h["award"])
      @description = h["description"]
      @status      = h["status"]
      @winner      = h["winner"] || ""
      @expires_at  = parse_time(h["expires_at"])
      @created_at  = parse_time(h["created_at"])
    end

    attr_reader :id, :poster, :award, :description, :status,
                :winner, :expires_at, :created_at

    private :decimal, :parse_time
  end

  class Deposit < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @id          = h["id"]
      @depositor   = h["depositor"]
      @beneficiary = h["beneficiary"]
      @amount      = decimal(h["amount"])
      @status      = h["status"]
      @expires_at  = parse_time(h["expires_at"])
      @created_at  = parse_time(h["created_at"])
    end

    attr_reader :id, :depositor, :beneficiary, :amount,
                :status, :expires_at, :created_at

    private :decimal, :parse_time
  end

  class Intent < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @id         = h["id"]
      @from       = h["from"]
      @to         = h["to"]
      @amount     = decimal(h["amount"])
      @type       = h["type"]
      @expires_at = parse_time(h["expires_at"])
      @created_at = parse_time(h["created_at"])
    end

    attr_reader :id, :from, :to, :amount, :type, :expires_at, :created_at

    private :decimal, :parse_time
  end

  class Budget < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @daily_limit       = decimal(h["daily_limit"])
      @daily_used        = decimal(h["daily_used"])
      @daily_remaining   = decimal(h["daily_remaining"])
      @monthly_limit     = decimal(h["monthly_limit"])
      @monthly_used      = decimal(h["monthly_used"])
      @monthly_remaining = decimal(h["monthly_remaining"])
      @per_tx_limit      = decimal(h["per_tx_limit"])
    end

    attr_reader :daily_limit, :daily_used, :daily_remaining,
                :monthly_limit, :monthly_used, :monthly_remaining, :per_tx_limit

    private :decimal
  end

  class SpendingSummary < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @address        = h["address"]
      @period         = h["period"]
      @total_spent    = decimal(h["total_spent"])
      @total_fees     = decimal(h["total_fees"])
      @tx_count       = h["tx_count"]&.to_i || 0
      @top_recipients = h["top_recipients"] || []
    end

    attr_reader :address, :period, :total_spent, :total_fees,
                :tx_count, :top_recipients

    private :decimal
  end

  # One-time operator link for funding or withdrawing.
  class LinkResponse < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @url            = h["url"]
      @token          = h["token"]
      @expires_at     = h["expires_at"]
      @wallet_address = h["wallet_address"]
    end

    attr_reader :url, :token, :expires_at, :wallet_address
  end

  class TransactionList < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      items_raw = h["items"] || []
      @items    = items_raw.map { |tx| Transaction.new(tx) }
      @total    = h["total"]&.to_i || 0
      @page     = h["page"]&.to_i || 1
      @per_page = h["per_page"]&.to_i || 50
      @has_more = h["has_more"] == true
    end

    attr_reader :items, :total, :page, :per_page, :has_more
  end
end
