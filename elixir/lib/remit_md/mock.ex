defmodule RemitMd.MockRemit do
  @moduledoc """
  In-memory mock of the remit.md API for testing. Implements the full
  payment API without network or blockchain - completes in microseconds.

  `MockRemit` is an OTP `GenServer`. Start it under a supervisor or with
  `start_link/1` in a test. Pass the pid to `RemitMd.Wallet.new/1`.

  ## Example

      test "agent pays for a service" do
        {:ok, mock} = RemitMd.MockRemit.start_link()
        RemitMd.MockRemit.set_balance(mock, "0xPayer", "100.00")

        wallet = RemitMd.Wallet.new(mock: mock, address: "0xPayer")
        {:ok, tx} = RemitMd.Wallet.pay(wallet, "0xRecipient", "5.00")

        assert tx.status == "confirmed"
        assert RemitMd.MockRemit.was_paid?(mock, "0xRecipient")
        assert RemitMd.MockRemit.total_paid_to(mock, "0xRecipient") == "5.00"
      end
  """

  use GenServer

  @default_balance "1000.00"
  @default_reputation_score 85
  @fee_rate "0.001" # 0.1%

  # ─── Public API ───────────────────────────────────────────────────────────

  @doc "Start a MockRemit GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, opts)
  end

  @doc "Set the USDC balance for a wallet address."
  def set_balance(pid, address, amount_usdc) do
    GenServer.call(pid, {:set_balance, address, amount_usdc})
  end

  @doc "Set the reputation score for a wallet address (0–100)."
  def set_reputation(pid, address, score) do
    GenServer.call(pid, {:set_reputation, address, score})
  end

  @doc "Return true if any payment was sent TO the given address."
  def was_paid?(pid, address) do
    GenServer.call(pid, {:was_paid, address})
  end

  @doc "Return the total USDC sent TO the given address across all payments."
  def total_paid_to(pid, address) do
    GenServer.call(pid, {:total_paid_to, address})
  end

  @doc "Return the number of transactions recorded."
  def transaction_count(pid) do
    GenServer.call(pid, :transaction_count)
  end

  @doc "Reset all state (balances, transactions, escrows, etc.)."
  def reset(pid) do
    GenServer.call(pid, :reset)
  end

  # ─── Payment Operations (called by MockTransport) ─────────────────────────

  @doc false
  def do_pay(pid, from, to, amount_usdc, opts) do
    GenServer.call(pid, {:pay, from, to, amount_usdc, opts})
  end

  @doc false
  def do_balance(pid, address) do
    GenServer.call(pid, {:balance, address})
  end

  @doc false
  def do_reputation(pid, address) do
    GenServer.call(pid, {:reputation, address})
  end

  @doc false
  def do_history(pid, address, opts) do
    GenServer.call(pid, {:history, address, opts})
  end

  @doc false
  def do_create_escrow(pid, from, to, amount_usdc, opts) do
    GenServer.call(pid, {:create_escrow, from, to, amount_usdc, opts})
  end

  @doc false
  def do_pay_milestone(pid, from, escrow_id, milestone_id) do
    GenServer.call(pid, {:pay_milestone, from, escrow_id, milestone_id})
  end

  @doc false
  def do_cancel_escrow(pid, from, escrow_id) do
    GenServer.call(pid, {:cancel_escrow, from, escrow_id})
  end

  @doc false
  def do_spending(pid, address, opts) do
    GenServer.call(pid, {:spending, address, opts})
  end

  # ─── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, initial_state()}
  end

  @impl true
  def handle_call({:set_balance, address, amount}, _from, state) do
    balances = Map.put(state.balances, address, amount)
    {:reply, :ok, %{state | balances: balances}}
  end

  def handle_call({:set_reputation, address, score}, _from, state) do
    reps = Map.put(state.reputations, address, score)
    {:reply, :ok, %{state | reputations: reps}}
  end

  def handle_call({:was_paid, address}, _from, state) do
    result = state.transactions |> Enum.any?(fn tx -> tx["to"] == address end)
    {:reply, result, state}
  end

  def handle_call({:total_paid_to, address}, _from, state) do
    total =
      state.transactions
      |> Enum.filter(fn tx -> tx["to"] == address end)
      |> Enum.reduce(Decimal.new("0"), fn tx, acc ->
        Decimal.add(acc, Decimal.new(tx["amount_usdc"]))
      end)

    {:reply, Decimal.to_string(total), state}
  end

  def handle_call(:transaction_count, _from, state) do
    {:reply, length(state.transactions), state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, initial_state()}
  end

  def handle_call({:pay, from, to, amount_usdc, _opts}, _from, state) do
    with :ok <- check_balance(state, from, amount_usdc),
         :ok <- check_not_same(from, to) do
      fee = compute_fee(amount_usdc)
      tx = make_tx("pay", from, to, amount_usdc, fee)
      state = %{state | transactions: [tx | state.transactions]}
      {:reply, {:ok, tx}, state}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:balance, address}, _from, state) do
    usdc = Map.get(state.balances, address, @default_balance)

    result = %{
      "address"  => address,
      "usdc"     => usdc,
      "chain_id" => 84532
    }

    {:reply, {:ok, result}, state}
  end

  def handle_call({:reputation, address}, _from, state) do
    score = Map.get(state.reputations, address, @default_reputation_score)
    count = state.transactions |> Enum.count(fn tx -> tx["to"] == address || tx["from"] == address end)

    result = %{
      "address"             => address,
      "score"               => score,
      "total_volume_usdc"   => "0.00",
      "successful_txns"     => count,
      "avg_settlement_secs" => 1,
      "member_since"        => "2026-01-01T00:00:00Z"
    }

    {:reply, {:ok, result}, state}
  end

  def handle_call({:history, address, opts}, _from, state) do
    limit  = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    relevant =
      state.transactions
      |> Enum.filter(fn tx -> tx["from"] == address || tx["to"] == address end)

    items = relevant |> Enum.drop(offset) |> Enum.take(limit)

    result = %{
      "items"  => items,
      "total"  => length(relevant),
      "limit"  => limit,
      "offset" => offset
    }

    {:reply, {:ok, result}, state}
  end

  def handle_call({:create_escrow, from, to, amount_usdc, opts}, _from, state) do
    with :ok <- check_balance(state, from, amount_usdc),
         :ok <- check_not_same(from, to) do
      milestones = Keyword.get(opts, :milestones, ["complete"])
      fee = compute_fee(amount_usdc)
      escrow_id = "esc_" <> generate_id()

      escrow = %{
        "escrow_id"   => escrow_id,
        "from"        => from,
        "to"          => to,
        "amount_usdc" => amount_usdc,
        "fee_usdc"    => fee,
        "status"      => "pending",
        "milestones"  => Enum.map(milestones, fn m -> %{"id" => m, "status" => "pending"} end),
        "created_at"  => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      state = %{state | escrows: Map.put(state.escrows, escrow_id, escrow)}
      {:reply, {:ok, escrow}, state}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:pay_milestone, from, escrow_id, milestone_id}, _from, state) do
    case Map.get(state.escrows, escrow_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{"from" => owner} = _escrow when owner != from ->
        {:reply, {:error, :forbidden}, state}

      escrow ->
        milestones =
          Enum.map(escrow["milestones"], fn m ->
            if m["id"] == milestone_id, do: Map.put(m, "status", "released"), else: m
          end)

        all_done = Enum.all?(milestones, fn m -> m["status"] == "released" end)
        new_status = if all_done, do: "complete", else: "partial"

        updated = %{escrow | "milestones" => milestones, "status" => new_status}
        state = %{state | escrows: Map.put(state.escrows, escrow_id, updated)}
        {:reply, {:ok, updated}, state}
    end
  end

  def handle_call({:cancel_escrow, from, escrow_id}, _from, state) do
    case Map.get(state.escrows, escrow_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{"from" => owner} = _escrow when owner != from ->
        {:reply, {:error, :forbidden}, state}

      escrow ->
        cancelled = Map.put(escrow, "status", "cancelled")
        state = %{state | escrows: Map.put(state.escrows, escrow_id, cancelled)}
        {:reply, {:ok, cancelled}, state}
    end
  end

  def handle_call({:spending, address, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 30)

    sent =
      state.transactions
      |> Enum.filter(fn tx -> tx["from"] == address end)

    total =
      Enum.reduce(sent, Decimal.new("0"), fn tx, acc ->
        Decimal.add(acc, Decimal.new(tx["amount_usdc"]))
      end)

    result = %{
      "address"           => address,
      "total_spent_usdc"  => Decimal.to_string(total),
      "transaction_count" => length(sent),
      "top_recipients"    => [],
      "period_start"      => DateTime.utc_now() |> DateTime.add(-limit * 86400, :second) |> DateTime.to_iso8601(),
      "period_end"        => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:reply, {:ok, result}, state}
  end

  # ─── Helpers ──────────────────────────────────────────────────────────────

  defp initial_state do
    %{
      balances:     %{},
      reputations:  %{},
      transactions: [],
      escrows:      %{}
    }
  end

  defp check_balance(state, address, amount_usdc) do
    balance = Map.get(state.balances, address, @default_balance)

    if Decimal.compare(Decimal.new(balance), Decimal.new(amount_usdc)) == :lt do
      {:error,
       RemitMd.Error.new(
         RemitMd.Error.insufficient_balance(),
         "Balance #{balance} USDC < #{amount_usdc} USDC required"
       )}
    else
      :ok
    end
  end

  defp check_not_same(from, to) do
    if from == to do
      {:error,
       RemitMd.Error.new(
         RemitMd.Error.self_payment(),
         "Payer and payee cannot be the same address"
       )}
    else
      :ok
    end
  end

  defp make_tx(model, from, to, amount_usdc, fee_usdc) do
    %{
      "tx_id"       => "tx_" <> generate_id(),
      "from"        => from,
      "to"          => to,
      "amount_usdc" => amount_usdc,
      "fee_usdc"    => fee_usdc,
      "model"       => model,
      "status"      => "confirmed",
      "tx_hash"     => "0x" <> generate_id() <> generate_id(),
      "chain_id"    => 84532,
      "created_at"  => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp compute_fee(amount_usdc) do
    Decimal.new(amount_usdc)
    |> Decimal.mult(Decimal.new(@fee_rate))
    |> Decimal.to_string()
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
