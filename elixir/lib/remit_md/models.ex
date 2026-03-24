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
        tx_id:       Map.fetch!(m, "tx_id"),
        from:        Map.fetch!(m, "from"),
        to:          Map.fetch!(m, "to"),
        amount_usdc: Map.fetch!(m, "amount_usdc"),
        fee_usdc:    Map.get(m, "fee_usdc"),
        model:       Map.get(m, "model"),
        status:      Map.fetch!(m, "status"),
        tx_hash:     Map.get(m, "tx_hash"),
        chain_id:    Map.get(m, "chain_id"),
        created_at:  Map.fetch!(m, "created_at"),
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
        address:  Map.fetch!(m, "address"),
        usdc:     Map.fetch!(m, "usdc"),
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
        address:              Map.fetch!(m, "address"),
        score:                Map.fetch!(m, "score"),
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
        escrow_id:   Map.fetch!(m, "escrow_id"),
        from:        Map.fetch!(m, "from"),
        to:          Map.fetch!(m, "to"),
        amount_usdc: Map.fetch!(m, "amount_usdc"),
        fee_usdc:    Map.get(m, "fee_usdc"),
        status:      Map.fetch!(m, "status"),
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
        tab_id:               Map.fetch!(m, "tab_id"),
        from:                 Map.fetch!(m, "from"),
        to:                   Map.fetch!(m, "to"),
        credit_limit_usdc:    Map.get(m, "credit_limit_usdc"),
        current_balance_usdc: Map.get(m, "current_balance_usdc"),
        status:               Map.fetch!(m, "status"),
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
        stream_id:            Map.fetch!(m, "stream_id"),
        from:                 Map.fetch!(m, "from"),
        to:                   Map.fetch!(m, "to"),
        rate_per_second_usdc: Map.fetch!(m, "rate_per_second_usdc"),
        total_amount_usdc:    Map.get(m, "total_amount_usdc"),
        streamed_usdc:        Map.get(m, "streamed_usdc"),
        status:               Map.fetch!(m, "status"),
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
        bounty_id:   Map.fetch!(m, "bounty_id"),
        poster:      Map.fetch!(m, "poster"),
        amount_usdc: Map.fetch!(m, "amount_usdc"),
        fee_usdc:    Map.get(m, "fee_usdc"),
        description: Map.get(m, "description"),
        status:      Map.fetch!(m, "status"),
        winner:      Map.get(m, "winner"),
        created_at:  Map.get(m, "created_at"),
        expires_at:  Map.get(m, "expires_at")
      }
    end
  end

  defmodule Deposit do
    @moduledoc "A refundable deposit held by a provider."
    @enforce_keys [:deposit_id, :status]
    defstruct [:deposit_id, :payer, :provider, :amount_usdc,
               :status, :created_at, :expires_at, :tx_hash]

    @doc false
    def from_map(m) do
      deposit_id = Map.get(m, "deposit_id") || Map.get(m, "id") ||
        raise KeyError, key: "deposit_id", term: m
      status = Map.fetch!(m, "status")
      %__MODULE__{
        deposit_id:  deposit_id,
        payer:       Map.get(m, "payer") || Map.get(m, "from"),
        provider:    Map.get(m, "provider") || Map.get(m, "to"),
        amount_usdc: Map.get(m, "amount_usdc") || Map.get(m, "amount"),
        status:      status,
        created_at:  Map.get(m, "created_at"),
        expires_at:  Map.get(m, "expires_at"),
        tx_hash:     Map.get(m, "tx_hash")
      }
    end
  end

  defmodule TabCharge do
    @moduledoc "A charge against an open tab."
    @enforce_keys [:tab_id]
    defstruct [:tab_id, :amount, :cumulative, :call_count, :created_at]

    @doc false
    def from_map(m) do
      %__MODULE__{
        tab_id:     Map.fetch!(m, "tab_id"),
        amount:     Map.get(m, "amount"),
        cumulative: Map.get(m, "cumulative"),
        call_count: Map.get(m, "call_count"),
        created_at: Map.get(m, "created_at")
      }
    end
  end

  defmodule BountySubmission do
    @moduledoc "A submission for a bounty."
    @enforce_keys [:id, :bounty_id]
    defstruct [:id, :bounty_id, :submitter, :evidence_hash, :status, :created_at]

    @doc false
    def from_map(m) do
      %__MODULE__{
        id:            Map.fetch!(m, "id"),
        bounty_id:     Map.fetch!(m, "bounty_id"),
        submitter:     Map.get(m, "submitter"),
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
        expires_at:     Map.get(m, "expires_at"),
        wallet_address: Map.get(m, "wallet_address")
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
        created_at: Map.get(m, "created_at"),
        updated_at: Map.get(m, "updated_at")
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
        chain_id:       Map.fetch!(m, "chain_id"),
        usdc:           Map.fetch!(m, "usdc"),
        router:         Map.fetch!(m, "router"),
        escrow:         Map.get(m, "escrow"),
        tab:            Map.get(m, "tab"),
        stream:         Map.get(m, "stream"),
        bounty:         Map.get(m, "bounty"),
        deposit:        Map.get(m, "deposit"),
        fee_calculator: Map.get(m, "fee_calculator"),
        key_registry:   Map.get(m, "key_registry"),
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
