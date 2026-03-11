defmodule RemitMd.Models do
  @moduledoc """
  Response structs returned by `RemitMd.Wallet` payment operations.
  All monetary amounts are `Decimal`-compatible strings (e.g. `"1.50"`).
  """

  defmodule Transaction do
    @moduledoc "A confirmed remit.md payment transaction."
    @enforce_keys [:tx_id, :from, :to, :amount_usdc, :status, :created_at]
    defstruct [:tx_id, :from, :to, :amount_usdc, :fee_usdc, :model,
               :status, :tx_hash, :chain_id, :created_at, :metadata]

    @doc false
    def from_map(m) do
      %__MODULE__{
        tx_id:       Map.get(m, "tx_id"),
        from:        Map.get(m, "from"),
        to:          Map.get(m, "to"),
        amount_usdc: Map.get(m, "amount_usdc"),
        fee_usdc:    Map.get(m, "fee_usdc"),
        model:       Map.get(m, "model"),
        status:      Map.get(m, "status"),
        tx_hash:     Map.get(m, "tx_hash"),
        chain_id:    Map.get(m, "chain_id"),
        created_at:  Map.get(m, "created_at"),
        metadata:    Map.get(m, "metadata")
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
        address:  Map.get(m, "address"),
        usdc:     Map.get(m, "usdc"),
        chain_id: Map.get(m, "chain_id")
      }
    end
  end

  defmodule Reputation do
    @moduledoc "Reputation score and statistics for an agent address."
    @enforce_keys [:address, :score]
    defstruct [:address, :score, :total_volume_usdc, :successful_txns,
               :avg_settlement_secs, :member_since]

    @doc false
    def from_map(m) do
      %__MODULE__{
        address:              Map.get(m, "address"),
        score:                Map.get(m, "score"),
        total_volume_usdc:    Map.get(m, "total_volume_usdc"),
        successful_txns:      Map.get(m, "successful_txns"),
        avg_settlement_secs:  Map.get(m, "avg_settlement_secs"),
        member_since:         Map.get(m, "member_since")
      }
    end
  end

  defmodule Escrow do
    @moduledoc "An escrow payment with milestone-based release."
    @enforce_keys [:escrow_id, :from, :to, :amount_usdc, :status]
    defstruct [:escrow_id, :from, :to, :amount_usdc, :fee_usdc,
               :status, :milestones, :created_at, :expires_at]

    @doc false
    def from_map(m) do
      %__MODULE__{
        escrow_id:   Map.get(m, "escrow_id"),
        from:        Map.get(m, "from"),
        to:          Map.get(m, "to"),
        amount_usdc: Map.get(m, "amount_usdc"),
        fee_usdc:    Map.get(m, "fee_usdc"),
        status:      Map.get(m, "status"),
        milestones:  Map.get(m, "milestones"),
        created_at:  Map.get(m, "created_at"),
        expires_at:  Map.get(m, "expires_at")
      }
    end
  end

  defmodule Tab do
    @moduledoc "An off-chain payment tab — batch transactions, settle periodically."
    @enforce_keys [:tab_id, :from, :to, :status]
    defstruct [:tab_id, :from, :to, :credit_limit_usdc, :current_balance_usdc,
               :status, :created_at, :expires_at]

    @doc false
    def from_map(m) do
      %__MODULE__{
        tab_id:               Map.get(m, "tab_id"),
        from:                 Map.get(m, "from"),
        to:                   Map.get(m, "to"),
        credit_limit_usdc:    Map.get(m, "credit_limit_usdc"),
        current_balance_usdc: Map.get(m, "current_balance_usdc"),
        status:               Map.get(m, "status"),
        created_at:           Map.get(m, "created_at"),
        expires_at:           Map.get(m, "expires_at")
      }
    end
  end

  defmodule Stream do
    @moduledoc "A payment stream — continuous USDC flow per second."
    @enforce_keys [:stream_id, :from, :to, :rate_per_second_usdc, :status]
    defstruct [:stream_id, :from, :to, :rate_per_second_usdc, :total_amount_usdc,
               :streamed_usdc, :status, :started_at, :ends_at]

    @doc false
    def from_map(m) do
      %__MODULE__{
        stream_id:            Map.get(m, "stream_id"),
        from:                 Map.get(m, "from"),
        to:                   Map.get(m, "to"),
        rate_per_second_usdc: Map.get(m, "rate_per_second_usdc"),
        total_amount_usdc:    Map.get(m, "total_amount_usdc"),
        streamed_usdc:        Map.get(m, "streamed_usdc"),
        status:               Map.get(m, "status"),
        started_at:           Map.get(m, "started_at"),
        ends_at:              Map.get(m, "ends_at")
      }
    end
  end

  defmodule Bounty do
    @moduledoc "A bounty — pay any agent that completes the task."
    @enforce_keys [:bounty_id, :poster, :amount_usdc, :status]
    defstruct [:bounty_id, :poster, :amount_usdc, :fee_usdc,
               :description, :status, :winner, :created_at, :expires_at]

    @doc false
    def from_map(m) do
      %__MODULE__{
        bounty_id:   Map.get(m, "bounty_id"),
        poster:      Map.get(m, "poster"),
        amount_usdc: Map.get(m, "amount_usdc"),
        fee_usdc:    Map.get(m, "fee_usdc"),
        description: Map.get(m, "description"),
        status:      Map.get(m, "status"),
        winner:      Map.get(m, "winner"),
        created_at:  Map.get(m, "created_at"),
        expires_at:  Map.get(m, "expires_at")
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
        address:        Map.get(m, "address"),
        limit_usdc:     Map.get(m, "limit_usdc"),
        spent_usdc:     Map.get(m, "spent_usdc"),
        remaining_usdc: Map.get(m, "remaining_usdc"),
        period:         Map.get(m, "period"),
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
        address:           Map.get(m, "address"),
        total_spent_usdc:  Map.get(m, "total_spent_usdc"),
        transaction_count: Map.get(m, "transaction_count"),
        top_recipients:    Map.get(m, "top_recipients"),
        period_start:      Map.get(m, "period_start"),
        period_end:        Map.get(m, "period_end")
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
        total:  Map.get(m, "total"),
        limit:  Map.get(m, "limit"),
        offset: Map.get(m, "offset")
      }
    end
  end
end
