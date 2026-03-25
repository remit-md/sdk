defmodule RemitMd.Models do
  @moduledoc """
  Response structs returned by `RemitMd.Wallet` payment operations.
  All monetary amounts are `Decimal`-compatible strings (e.g. `"1.50"`).
  """

  defmodule Transaction do
    @moduledoc "A confirmed remit.md payment transaction."
    @enforce_keys [:status]
    defstruct [:invoice_id, :tx_hash, :chain, :status, :created_at,
               # Legacy fields (backward compat)
               :tx_id, :from, :to, :amount_usdc, :fee_usdc, :model,
               :chain_id, :metadata]

    @doc false
    def from_map(m) do
      %__MODULE__{
        invoice_id:  Map.get(m, "invoice_id") || Map.get(m, "tx_id"),
        tx_hash:     Map.get(m, "tx_hash"),
        chain:       Map.get(m, "chain") || Map.get(m, "chain_id"),
        status:      Map.get(m, "status") || "unknown",
        created_at:  Map.get(m, "created_at"),
        # Legacy fields
        tx_id:       Map.get(m, "tx_id") || Map.get(m, "invoice_id"),
        from:        Map.get(m, "from"),
        to:          Map.get(m, "to"),
        amount_usdc: Map.get(m, "amount_usdc") || Map.get(m, "amount"),
        fee_usdc:    Map.get(m, "fee_usdc"),
        model:       Map.get(m, "model"),
        chain_id:    Map.get(m, "chain_id") || Map.get(m, "chain"),
        metadata:    Map.get(m, "metadata")
      }
    end
  end

  defmodule WalletStatus do
    @moduledoc "Wallet status including balance and tier info."
    defstruct [:wallet, :balance, :monthly_volume, :tier, :fee_rate_bps,
               :active_escrows, :active_tabs, :active_streams, :permit_nonce]

    @type t :: %__MODULE__{
      wallet: String.t() | nil,
      balance: String.t() | nil,
      monthly_volume: String.t() | nil,
      tier: String.t() | nil,
      fee_rate_bps: integer() | nil,
      active_escrows: integer() | nil,
      active_tabs: integer() | nil,
      active_streams: integer() | nil,
      permit_nonce: integer() | nil
    }

    @doc false
    def from_map(m) do
      %__MODULE__{
        wallet:          Map.get(m, "wallet"),
        balance:         Map.get(m, "balance"),
        monthly_volume:  Map.get(m, "monthly_volume") || Map.get(m, "monthlyVolume"),
        tier:            Map.get(m, "tier"),
        fee_rate_bps:    Map.get(m, "fee_rate_bps") || Map.get(m, "feeRateBps"),
        active_escrows:  Map.get(m, "active_escrows") || Map.get(m, "activeEscrows"),
        active_tabs:     Map.get(m, "active_tabs") || Map.get(m, "activeTabs"),
        active_streams:  Map.get(m, "active_streams") || Map.get(m, "activeStreams"),
        permit_nonce:    Map.get(m, "permit_nonce") || Map.get(m, "permitNonce")
      }
    end
  end

  defmodule Balance do
    @moduledoc "USDC balance for a wallet address."
    @enforce_keys [:address, :usdc]
    defstruct [:address, :usdc, :chain_id]

    @doc false
    def from_map(m) do
      %__MODULE__{
        address:  Map.fetch!(m, "address"),
        usdc:     Map.fetch!(m, "usdc"),
        chain_id: Map.get(m, "chain_id")
      }
    end
  end

  defmodule Reputation do
    @moduledoc "Reputation score and statistics for an agent address."
    @enforce_keys [:address, :score]
    defstruct [:address, :score, :total_paid, :total_received,
               :escrows_completed, :member_since,
               # Legacy fields
               :total_volume_usdc, :successful_txns, :avg_settlement_secs]

    @doc false
    def from_map(m) do
      %__MODULE__{
        address:             Map.fetch!(m, "address"),
        score:               Map.fetch!(m, "score"),
        total_paid:          Map.get(m, "total_paid") || Map.get(m, "totalPaid"),
        total_received:      Map.get(m, "total_received") || Map.get(m, "totalReceived"),
        escrows_completed:   Map.get(m, "escrows_completed") || Map.get(m, "escrowsCompleted"),
        member_since:        Map.get(m, "member_since") || Map.get(m, "memberSince"),
        total_volume_usdc:   Map.get(m, "total_volume_usdc"),
        successful_txns:     Map.get(m, "successful_txns"),
        avg_settlement_secs: Map.get(m, "avg_settlement_secs")
      }
    end
  end

  defmodule Escrow do
    @moduledoc "An escrow payment with milestone-based release."
    @enforce_keys [:status]
    defstruct [:invoice_id, :tx_hash, :payer, :payee, :amount, :chain,
               :status, :milestone_index, :claim_started_at, :evidence_uri,
               :created_at, :expires_at,
               # Legacy fields
               :escrow_id, :from, :to, :amount_usdc, :fee_usdc, :milestones]

    @doc false
    def from_map(m) do
      %__MODULE__{
        invoice_id:       Map.get(m, "invoice_id") || Map.get(m, "invoiceId") || Map.get(m, "escrow_id"),
        tx_hash:          Map.get(m, "tx_hash") || Map.get(m, "txHash"),
        payer:            Map.get(m, "payer") || Map.get(m, "from"),
        payee:            Map.get(m, "payee") || Map.get(m, "to"),
        amount:           Map.get(m, "amount") || Map.get(m, "amount_usdc"),
        chain:            Map.get(m, "chain"),
        status:           Map.get(m, "status") || "unknown",
        milestone_index:  Map.get(m, "milestone_index") || Map.get(m, "milestoneIndex"),
        claim_started_at: Map.get(m, "claim_started_at") || Map.get(m, "claimStartedAt"),
        evidence_uri:     Map.get(m, "evidence_uri") || Map.get(m, "evidenceUri"),
        created_at:       Map.get(m, "created_at") || Map.get(m, "createdAt"),
        expires_at:       Map.get(m, "expires_at") || Map.get(m, "expiresAt"),
        # Legacy
        escrow_id:        Map.get(m, "escrow_id") || Map.get(m, "invoice_id") || Map.get(m, "invoiceId"),
        from:             Map.get(m, "from") || Map.get(m, "payer"),
        to:               Map.get(m, "to") || Map.get(m, "payee"),
        amount_usdc:      Map.get(m, "amount_usdc") || Map.get(m, "amount"),
        fee_usdc:         Map.get(m, "fee_usdc"),
        milestones:       Map.get(m, "milestones")
      }
    end
  end

  defmodule Tab do
    @moduledoc "An off-chain payment tab — batch transactions, settle periodically."
    @enforce_keys [:status]
    defstruct [:id, :payer, :payee, :limit, :per_unit, :spent, :chain,
               :status, :created_at, :expires_at,
               # Legacy fields
               :tab_id, :from, :to, :credit_limit_usdc, :current_balance_usdc]

    @doc false
    def from_map(m) do
      %__MODULE__{
        id:                  Map.get(m, "id") || Map.get(m, "tab_id"),
        payer:               Map.get(m, "payer") || Map.get(m, "from"),
        payee:               Map.get(m, "payee") || Map.get(m, "to"),
        limit:               Map.get(m, "limit") || Map.get(m, "credit_limit_usdc"),
        per_unit:            Map.get(m, "per_unit") || Map.get(m, "perUnit"),
        spent:               Map.get(m, "spent") || Map.get(m, "current_balance_usdc"),
        chain:               Map.get(m, "chain"),
        status:              Map.get(m, "status") || "unknown",
        created_at:          Map.get(m, "created_at") || Map.get(m, "createdAt"),
        expires_at:          Map.get(m, "expires_at") || Map.get(m, "expiresAt"),
        # Legacy
        tab_id:              Map.get(m, "tab_id") || Map.get(m, "id"),
        from:                Map.get(m, "from") || Map.get(m, "payer"),
        to:                  Map.get(m, "to") || Map.get(m, "payee"),
        credit_limit_usdc:   Map.get(m, "credit_limit_usdc") || Map.get(m, "limit"),
        current_balance_usdc: Map.get(m, "current_balance_usdc") || Map.get(m, "spent")
      }
    end
  end

  defmodule Stream do
    @moduledoc "A payment stream — continuous USDC flow per second."
    @enforce_keys [:status]
    defstruct [:id, :payer, :payee, :rate_per_second, :max_duration, :max_total,
               :total_streamed, :chain, :status, :started_at, :closed_at,
               # Legacy fields
               :stream_id, :from, :to, :rate_per_second_usdc, :total_amount_usdc,
               :streamed_usdc, :ends_at]

    @doc false
    def from_map(m) do
      %__MODULE__{
        id:                  Map.get(m, "id") || Map.get(m, "stream_id"),
        payer:               Map.get(m, "payer") || Map.get(m, "from"),
        payee:               Map.get(m, "payee") || Map.get(m, "to"),
        rate_per_second:     Map.get(m, "rate_per_second") || Map.get(m, "ratePerSecond") || Map.get(m, "rate_per_second_usdc"),
        max_duration:        Map.get(m, "max_duration") || Map.get(m, "maxDuration"),
        max_total:           Map.get(m, "max_total") || Map.get(m, "maxTotal") || Map.get(m, "total_amount_usdc"),
        total_streamed:      Map.get(m, "total_streamed") || Map.get(m, "totalStreamed") || Map.get(m, "streamed_usdc"),
        chain:               Map.get(m, "chain"),
        status:              Map.get(m, "status") || "unknown",
        started_at:          Map.get(m, "started_at") || Map.get(m, "startedAt"),
        closed_at:           Map.get(m, "closed_at") || Map.get(m, "closedAt"),
        # Legacy
        stream_id:           Map.get(m, "stream_id") || Map.get(m, "id"),
        from:                Map.get(m, "from") || Map.get(m, "payer"),
        to:                  Map.get(m, "to") || Map.get(m, "payee"),
        rate_per_second_usdc: Map.get(m, "rate_per_second_usdc") || Map.get(m, "rate_per_second") || Map.get(m, "ratePerSecond"),
        total_amount_usdc:   Map.get(m, "total_amount_usdc") || Map.get(m, "max_total") || Map.get(m, "maxTotal"),
        streamed_usdc:       Map.get(m, "streamed_usdc") || Map.get(m, "total_streamed") || Map.get(m, "totalStreamed"),
        ends_at:             Map.get(m, "ends_at") || Map.get(m, "closed_at") || Map.get(m, "closedAt")
      }
    end
  end

  defmodule Bounty do
    @moduledoc "A bounty — pay any agent that completes the task."
    @enforce_keys [:status]
    defstruct [:id, :poster, :amount, :task, :chain, :status,
               :validation, :max_attempts, :submissions, :winner,
               :created_at, :deadline,
               # Legacy fields
               :bounty_id, :amount_usdc, :fee_usdc, :description, :expires_at]

    @doc false
    def from_map(m) do
      %__MODULE__{
        id:           Map.get(m, "id") || Map.get(m, "bounty_id"),
        poster:       Map.get(m, "poster"),
        amount:       Map.get(m, "amount") || Map.get(m, "amount_usdc"),
        task:         Map.get(m, "task") || Map.get(m, "description"),
        chain:        Map.get(m, "chain"),
        status:       Map.get(m, "status") || "unknown",
        validation:   Map.get(m, "validation"),
        max_attempts: Map.get(m, "max_attempts") || Map.get(m, "maxAttempts"),
        submissions:  Map.get(m, "submissions") || [],
        winner:       Map.get(m, "winner"),
        created_at:   Map.get(m, "created_at") || Map.get(m, "createdAt"),
        deadline:     Map.get(m, "deadline") || Map.get(m, "expires_at"),
        # Legacy
        bounty_id:    Map.get(m, "bounty_id") || Map.get(m, "id"),
        amount_usdc:  Map.get(m, "amount_usdc") || Map.get(m, "amount"),
        fee_usdc:     Map.get(m, "fee_usdc"),
        description:  Map.get(m, "description") || Map.get(m, "task"),
        expires_at:   Map.get(m, "expires_at") || Map.get(m, "deadline")
      }
    end
  end

  defmodule Deposit do
    @moduledoc "A refundable deposit held by a provider."
    @enforce_keys [:status]
    defstruct [:id, :payer, :payee, :amount, :chain, :status,
               :created_at, :expires_at, :released_at,
               # Legacy fields
               :deposit_id, :provider, :amount_usdc, :tx_hash]

    @doc false
    def from_map(m) do
      %__MODULE__{
        id:          Map.get(m, "id") || Map.get(m, "deposit_id"),
        payer:       Map.get(m, "payer") || Map.get(m, "from"),
        payee:       Map.get(m, "payee") || Map.get(m, "to") || Map.get(m, "provider"),
        amount:      Map.get(m, "amount") || Map.get(m, "amount_usdc"),
        chain:       Map.get(m, "chain"),
        status:      Map.get(m, "status") || "unknown",
        created_at:  Map.get(m, "created_at") || Map.get(m, "createdAt"),
        expires_at:  Map.get(m, "expires_at") || Map.get(m, "expiresAt"),
        released_at: Map.get(m, "released_at") || Map.get(m, "releasedAt"),
        # Legacy
        deposit_id:  Map.get(m, "deposit_id") || Map.get(m, "id"),
        provider:    Map.get(m, "provider") || Map.get(m, "to") || Map.get(m, "payee"),
        amount_usdc: Map.get(m, "amount_usdc") || Map.get(m, "amount"),
        tx_hash:     Map.get(m, "tx_hash") || Map.get(m, "txHash")
      }
    end
  end

  defmodule TabCharge do
    @moduledoc "A charge against an open tab."
    defstruct [:tab_id, :amount, :units, :memo, :charged_at,
               # Legacy fields
               :cumulative, :call_count, :created_at]

    @doc false
    def from_map(m) do
      %__MODULE__{
        tab_id:     Map.get(m, "tab_id") || Map.get(m, "tabId"),
        amount:     Map.get(m, "amount"),
        units:      Map.get(m, "units"),
        memo:       Map.get(m, "memo"),
        charged_at: Map.get(m, "charged_at") || Map.get(m, "chargedAt"),
        # Legacy
        cumulative: Map.get(m, "cumulative"),
        call_count: Map.get(m, "call_count"),
        created_at: Map.get(m, "created_at")
      }
    end
  end

  defmodule BountySubmission do
    @moduledoc "A submission for a bounty."
    defstruct [:submitter, :evidence_uri, :submitted_at, :accepted,
               # Legacy fields
               :id, :bounty_id, :evidence_hash, :status, :created_at]

    @doc false
    def from_map(m) do
      %__MODULE__{
        submitter:     Map.get(m, "submitter"),
        evidence_uri:  Map.get(m, "evidence_uri") || Map.get(m, "evidenceUri"),
        submitted_at:  Map.get(m, "submitted_at") || Map.get(m, "submittedAt"),
        accepted:      Map.get(m, "accepted"),
        # Legacy
        id:            Map.get(m, "id"),
        bounty_id:     Map.get(m, "bounty_id"),
        evidence_hash: Map.get(m, "evidence_hash"),
        status:        Map.get(m, "status"),
        created_at:    Map.get(m, "created_at")
      }
    end
  end

  defmodule Budget do
    @moduledoc "Spending budget and remaining allowance set by an operator."
    @enforce_keys [:address, :limit_usdc, :spent_usdc, :remaining_usdc, :period]
    defstruct [:address, :limit_usdc, :spent_usdc, :remaining_usdc, :period, :resets_at]

    @doc false
    def from_map(m) do
      %__MODULE__{
        address:        Map.fetch!(m, "address"),
        limit_usdc:     Map.fetch!(m, "limit_usdc"),
        spent_usdc:     Map.fetch!(m, "spent_usdc"),
        remaining_usdc: Map.fetch!(m, "remaining_usdc"),
        period:         Map.fetch!(m, "period"),
        resets_at:      Map.get(m, "resets_at")
      }
    end
  end

  defmodule SpendingSummary do
    @moduledoc "Spending analytics for the wallet."
    @enforce_keys [:address, :total_spent_usdc, :transaction_count]
    defstruct [:address, :total_spent_usdc, :transaction_count,
               :top_recipients, :period_start, :period_end]

    @doc false
    def from_map(m) do
      %__MODULE__{
        address:           Map.fetch!(m, "address"),
        total_spent_usdc:  Map.fetch!(m, "total_spent_usdc"),
        transaction_count: Map.fetch!(m, "transaction_count"),
        top_recipients:    Map.get(m, "top_recipients"),
        period_start:      Map.get(m, "period_start"),
        period_end:        Map.get(m, "period_end")
      }
    end
  end

  defmodule LinkResponse do
    @moduledoc "One-time operator link for funding or withdrawing a wallet."
    @enforce_keys [:url, :token]
    defstruct [:url, :token, :expires_at, :wallet_address]

    @doc false
    def from_map(m) do
      %__MODULE__{
        url:            Map.fetch!(m, "url"),
        token:          Map.fetch!(m, "token"),
        expires_at:     Map.get(m, "expires_at") || Map.get(m, "expiresAt"),
        wallet_address: Map.get(m, "wallet_address") || Map.get(m, "walletAddress")
      }
    end
  end

  defmodule Webhook do
    @moduledoc "A registered webhook endpoint."
    @enforce_keys [:id, :wallet, :url, :events, :active]
    defstruct [:id, :wallet, :url, :events, :chains, :active, :created_at, :updated_at]

    @doc false
    def from_map(m) do
      %__MODULE__{
        id:         Map.fetch!(m, "id"),
        wallet:     Map.fetch!(m, "wallet"),
        url:        Map.fetch!(m, "url"),
        events:     Map.get(m, "events") || [],
        chains:     Map.get(m, "chains") || [],
        active:     Map.get(m, "active") == true,
        created_at: Map.get(m, "created_at") || Map.get(m, "createdAt"),
        updated_at: Map.get(m, "updated_at") || Map.get(m, "updatedAt")
      }
    end
  end

  defmodule TransactionList do
    @moduledoc "Paginated list of transactions."
    @enforce_keys [:items, :total, :limit, :offset]
    defstruct [:items, :total, :limit, :offset]

    @doc false
    def from_map(m) do
      items = (Map.get(m, "items") || []) |> Enum.map(&Transaction.from_map/1)
      %__MODULE__{
        items:  items,
        total:  Map.fetch!(m, "total"),
        limit:  Map.fetch!(m, "limit"),
        offset: Map.fetch!(m, "offset")
      }
    end
  end

  defmodule PermitSignature do
    @moduledoc "EIP-2612 permit signature for gasless USDC approvals."
    @enforce_keys [:value, :deadline, :v, :r, :s]
    defstruct [:value, :deadline, :v, :r, :s]

    @doc false
    def to_map(%__MODULE__{} = p) do
      %{value: p.value, deadline: p.deadline, v: p.v, r: p.r, s: p.s}
    end
  end

  defmodule ContractAddresses do
    @moduledoc "On-chain contract addresses for the current chain."
    @enforce_keys [:chain_id, :usdc, :router]
    defstruct [:chain_id, :usdc, :router, :escrow, :tab, :stream,
               :bounty, :deposit, :fee_calculator, :key_registry,
               :relayer]

    @doc false
    def from_map(m) do
      %__MODULE__{
        chain_id:       Map.get(m, "chain_id") || Map.get(m, "chainId"),
        usdc:           Map.get(m, "usdc"),
        router:         Map.get(m, "router"),
        escrow:         Map.get(m, "escrow"),
        tab:            Map.get(m, "tab"),
        stream:         Map.get(m, "stream"),
        bounty:         Map.get(m, "bounty"),
        deposit:        Map.get(m, "deposit"),
        fee_calculator: Map.get(m, "fee_calculator") || Map.get(m, "feeCalculator"),
        key_registry:   Map.get(m, "key_registry") || Map.get(m, "keyRegistry"),
        relayer:        Map.get(m, "relayer")
      }
    end
  end

  defmodule MintResponse do
    @moduledoc "Result of a testnet mint operation."
    @enforce_keys [:tx_hash, :balance]
    defstruct [:tx_hash, :balance]

    @doc false
    def from_map(m) do
      %__MODULE__{
        tx_hash: Map.fetch!(m, "tx_hash"),
        balance: Map.fetch!(m, "balance")
      }
    end
  end
end
