# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"
require "time"

module Remitmd
  # Supported chain IDs
  module ChainId
    BASE         = 8453
    BASE_SEPOLIA = 84532
  end

  # ─── Status types ─────────────────────────────────────────────────────────

  module EscrowStatus
    PENDING   = "pending"
    FUNDED    = "funded"
    ACTIVE    = "active"
    COMPLETED = "completed"
    CANCELLED = "cancelled"
    FAILED    = "failed"
  end

  module TabStatus
    OPEN      = "open"
    CLOSED    = "closed"
    EXPIRED   = "expired"
    SUSPENDED = "suspended"
  end

  module StreamStatus
    ACTIVE    = "active"
    CLOSED    = "closed"
    COMPLETED = "completed"
    PAUSED    = "paused"
    CANCELLED = "cancelled"
  end

  module BountyStatus
    OPEN      = "open"
    CLOSED    = "closed"
    AWARDED   = "awarded"
    EXPIRED   = "expired"
    CANCELLED = "cancelled"
  end

  module DepositStatus
    LOCKED    = "locked"
    RETURNED  = "returned"
    FORFEITED = "forfeited"
    EXPIRED   = "expired"
  end

  # ─── Permit & Contract Addresses ─────────────────────────────────────────

  # EIP-2612 permit signature for gasless USDC approval.
  class PermitSignature
    attr_reader :value, :deadline, :v, :r, :s

    def initialize(value:, deadline:, v:, r:, s:)
      @value    = value
      @deadline = deadline
      @v        = v
      @r        = r
      @s        = s
    end

    def to_h
      { value: @value, deadline: @deadline, v: @v, r: @r, s: @s }
    end
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

  # Contract addresses returned by GET /contracts.
  class ContractAddresses < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @chain_id       = h["chain_id"]&.to_i
      @usdc           = h["usdc"]
      @router         = h["router"]
      @escrow         = h["escrow"]
      @tab            = h["tab"]
      @stream         = h["stream"]
      @bounty         = h["bounty"]
      @deposit        = h["deposit"]
      @fee_calculator = h["fee_calculator"]
      @key_registry   = h["key_registry"]
      @relayer        = h["relayer"]
    end

    attr_reader :chain_id, :usdc, :router, :escrow, :tab, :stream,
                :bounty, :deposit, :fee_calculator, :key_registry,
                :relayer
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
      @block_number = h["block_number"].to_i
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
      @address           = h["wallet"] || h["address"]
      @score             = h["score"].to_i
      @total_paid        = decimal(h["total_paid"])
      @total_received    = decimal(h["total_received"])
      @transaction_count = h["transaction_count"].to_i
      @member_since      = parse_time(h["member_since"])
    end

    attr_reader :address, :score, :total_paid, :total_received,
                :transaction_count, :member_since

    private :decimal, :parse_time
  end

  class Escrow < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @id         = h["invoice_id"] || h["id"]
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
      @payer       = h["payer"] || h["opener"]
      @payee       = h["payee"] || h["provider"] || h["counterpart"]
      @limit       = decimal(h["limit_amount"] || h["limit"])
      @spent       = decimal(h["spent"] || h["used"] || "0")
      @remaining   = decimal(h["remaining"] || h["limit_amount"] || h["limit"])
      @status      = h["status"]
      @created_at  = parse_time(h["created_at"])
      @closes_at   = parse_time(h["closes_at"])
    end

    attr_reader :id, :payer, :payee, :limit, :spent, :remaining,
                :status, :created_at, :closes_at

    # Backward compatibility aliases
    alias opener payer
    alias provider payee
    alias counterpart payee
    alias used spent

    private :decimal, :parse_time
  end

  class TabDebit < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @tab_id     = h["tab_id"]
      @amount     = decimal(h["amount"])
      @cumulative = decimal(h["cumulative"])
      @call_count = h["call_count"].to_i
      @memo       = h["memo"] || ""
      @sequence   = h["sequence"].to_i
      @signature  = h["signature"]
    end

    attr_reader :tab_id, :amount, :cumulative, :call_count, :memo, :sequence, :signature

    private :decimal
  end

  class Stream < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @id              = h["id"]
      @payer           = h["payer"] || h["sender"]
      @payee           = h["payee"] || h["recipient"]
      @rate_per_second = decimal(h["rate_per_second"] || h["rate_per_sec"])
      @deposited       = decimal(h["deposited"])
      @total_streamed  = decimal(h["total_streamed"] || h["withdrawn"] || "0")
      @max_duration    = h["max_duration"]
      @max_total       = decimal(h["max_total"])
      @status          = h["status"]
      @started_at      = parse_time(h["started_at"])
      @ends_at         = parse_time(h["ends_at"])
      @closed_at       = parse_time(h["closed_at"])
    end

    attr_reader :id, :payer, :payee, :rate_per_second, :deposited,
                :total_streamed, :max_duration, :max_total,
                :status, :started_at, :ends_at, :closed_at

    # Backward compatibility aliases
    alias sender payer
    alias recipient payee
    alias rate_per_sec rate_per_second
    alias withdrawn total_streamed

    private :decimal, :parse_time
  end

  class Bounty < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @id           = h["id"]
      @poster       = h["poster"]
      @amount       = decimal(h["amount"] || h["award"])
      @task         = h["task"] || h["task_description"] || h["description"]
      @submissions  = h["submissions"] || []
      @validation   = h["validation"]
      @max_attempts = h["max_attempts"]
      @deadline     = h["deadline"]
      @status       = h["status"]
      @winner       = h["winner"] || ""
      @expires_at   = parse_time(h["expires_at"])
      @created_at   = parse_time(h["created_at"])
    end

    attr_reader :id, :poster, :amount, :task, :submissions, :validation,
                :max_attempts, :deadline, :status, :winner, :expires_at, :created_at

    # Backward compatibility aliases
    alias award amount
    alias task_description task
    alias description task

    private :decimal, :parse_time
  end

  class BountySubmission < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @id           = h["id"]
      @bounty_id    = h["bounty_id"]
      @submitter    = h["submitter"]
      @evidence_uri = h["evidence_uri"] || h["evidence_hash"]
      @accepted     = h.key?("accepted") ? h["accepted"] : h["status"]
      @created_at   = parse_time(h["created_at"])
    end

    attr_reader :id, :bounty_id, :submitter, :evidence_uri, :accepted, :created_at

    # Backward compatibility aliases
    alias evidence_hash evidence_uri
    alias status accepted

    private :parse_time
  end

  class Deposit < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @id          = h["id"]
      @payer       = h["payer"] || h["depositor"]
      @payee       = h["payee"] || h["provider"] || h["beneficiary"]
      @amount      = decimal(h["amount"])
      @status      = h["status"]
      @expires_at  = parse_time(h["expires_at"])
      @created_at  = parse_time(h["created_at"])
    end

    attr_reader :id, :payer, :payee, :amount,
                :status, :expires_at, :created_at

    # Backward compatibility aliases
    alias depositor payer
    alias provider payee
    alias beneficiary payee

    private :decimal, :parse_time
  end

  class WalletSettings < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @wallet       = h["wallet"]
      @display_name = h["display_name"]
    end

    attr_reader :wallet, :display_name
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
      @tx_count       = h["tx_count"].to_i
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

  class Webhook < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      @id         = h["id"]
      @wallet     = h["wallet"]
      @url        = h["url"]
      @events     = h["events"] || []
      @chains     = h["chains"] || []
      @active     = h["active"] == true
      @created_at = parse_time(h["created_at"])
      @updated_at = parse_time(h["updated_at"])
    end

    attr_reader :id, :wallet, :url, :events, :chains, :active, :created_at, :updated_at

    private :parse_time
  end

  class TransactionList < Model
    def initialize(attrs)
      h = attrs.transform_keys(&:to_s)
      items_raw = h["items"] || []
      @items    = items_raw.map { |tx| Transaction.new(tx) }
      @total    = h["total"].to_i
      @page     = (h["page"] || 1).to_i
      @per_page = (h["per_page"] || 50).to_i
      @has_more = h["has_more"] == true
    end

    attr_reader :items, :total, :page, :per_page, :has_more
  end
end
