defmodule RemitMd.Wallet do
  @moduledoc """
  Primary remit.md client. All payment operations are functions in this module.

  ## Quickstart

      # Testing with MockRemit (no network, no keys needed)
      {:ok, mock} = RemitMd.MockRemit.start_link()
      wallet = RemitMd.Wallet.new(mock: mock, address: "0xYourAgent")
      {:ok, tx} = RemitMd.Wallet.pay(wallet, "0xRecipient", "1.50")

      # Production (private key from env)
      wallet = RemitMd.Wallet.from_env()
      {:ok, tx} = RemitMd.Wallet.pay(wallet, "0xRecipient", "1.50")
      IO.puts("Sent! tx: \#{tx.tx_hash}")

  Private keys are held only in the `Signer` and never appear in `inspect/1`
  or log output.
  """

  alias RemitMd.{Error, Http, MockRemit, MockSigner, PrivateKeySigner}
  alias RemitMd.Models.{
    Balance, Bounty, Budget, ContractAddresses, Escrow, MintResponse, PermitSignature,
    Reputation, SpendingSummary, Stream, Tab, Transaction, TransactionList, Webhook
  }

  @min_amount Decimal.new("0.000001")

  defstruct [:signer, :transport, :mock_pid, :address, :chain]

  @type t :: %__MODULE__{
    signer:    term(),
    transport: term(),
    mock_pid:  pid() | nil,
    address:   String.t(),
    chain:     String.t() | nil
  }

  # ─── Constructors ─────────────────────────────────────────────────────────

  @doc """
  Create a wallet from a private key.

  ## Options

  - `:private_key` — 0x-prefixed 32-byte secp256k1 private key (required unless `:signer` given)
  - `:signer` — custom `RemitMd.Signer` implementation
  - `:chain` — `"base"` | `"base_sepolia"` (default: `"base"`)
  - `:api_url` — override API base URL
  - `:mock` — pid of a running `RemitMd.MockRemit` (disables real HTTP)
  - `:address` — address to use when in mock mode (optional, defaults to MockSigner address)
  """
  def new(opts) when is_list(opts) do
    mock_pid = Keyword.get(opts, :mock)

    if mock_pid do
      signer = MockSigner.new(Keyword.get(opts, :address, MockSigner.new().address))
      %__MODULE__{signer: signer, transport: nil, mock_pid: mock_pid, address: signer.address, chain: "base"}
    else
      signer =
        cond do
          key = Keyword.get(opts, :private_key) ->
            PrivateKeySigner.new(key)

          s = Keyword.get(opts, :signer) ->
            s

          true ->
            raise Error.new(Error.unauthorized(), "Provide :private_key or :signer")
        end

      transport = Http.new(opts |> Keyword.put(:signer, signer))
      address = get_address(signer)
      # Normalize to base chain name (strip testnet suffix) for use in pay body.
      # The server accepts "base" — not "base_sepolia" etc.
      chain = opts |> Keyword.get(:chain, "base") |> base_chain_name()
      %__MODULE__{signer: signer, transport: transport, mock_pid: nil, address: address, chain: chain}
    end
  end

  @doc """
  Build a wallet from environment variables.

  Required: `REMITMD_PRIVATE_KEY`
  Optional: `REMITMD_CHAIN`, `REMITMD_API_URL`, `REMITMD_ROUTER_ADDRESS`
  """
  def from_env do
    key =
      System.get_env("REMITMD_PRIVATE_KEY") ||
        raise Error.new(Error.unauthorized(), "REMITMD_PRIVATE_KEY not set")

    chain          = System.get_env("REMITMD_CHAIN", "base")
    api_url        = System.get_env("REMITMD_API_URL")
    router_address = System.get_env("REMITMD_ROUTER_ADDRESS")

    opts = [private_key: key, chain: chain]
    opts = if api_url, do: Keyword.put(opts, :api_url, api_url), else: opts
    opts = if router_address, do: Keyword.put(opts, :router_address, router_address), else: opts

    new(opts)
  end

  # ─── Balance & Analytics ──────────────────────────────────────────────────

  @doc """
  Fetch current USDC balance.
  Returns `{:ok, %RemitMd.Models.Balance{}}` or `{:error, %RemitMd.Error{}}`.
  """
  def balance(%__MODULE__{} = w) do
    with {:ok, data} <- call_mock_or_http(w, fn pid ->
           MockRemit.do_balance(pid, w.address)
         end, fn ->
           do_http_get(w, "/wallet/balance")
         end) do
      {:ok, Balance.from_map(data)}
    end
  end

  @doc """
  Fetch transaction history.

  Options: `:limit` (default 50), `:offset` (default 0).
  """
  def history(%__MODULE__{} = w, opts \\ []) do
    limit  = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    with {:ok, data} <- call_mock_or_http(w, fn pid ->
           MockRemit.do_history(pid, w.address, opts)
         end, fn ->
           do_http_get(w, "/wallet/transactions?limit=#{limit}&offset=#{offset}")
         end) do
      {:ok, TransactionList.from_map(data)}
    end
  end

  @doc """
  Fetch reputation score for an address (defaults to this wallet's address).
  """
  def reputation(%__MODULE__{} = w, address \\ nil) do
    addr = address || w.address

    with {:ok, data} <- call_mock_or_http(w, fn pid ->
           MockRemit.do_reputation(pid, addr)
         end, fn ->
           do_http_get(w, "/reputation/#{addr}")
         end) do
      {:ok, Reputation.from_map(data)}
    end
  end

  @doc """
  Fetch operator-set spending budget.
  """
  def budget(%__MODULE__{} = w) do
    with {:ok, data} <- call_mock_or_http(w, fn _pid ->
           {:ok, %{}}  # Budget not implemented in mock
         end, fn ->
           do_http_get(w, "/wallet/budget")
         end) do
      {:ok, Budget.from_map(data)}
    end
  end

  @doc """
  Fetch spending summary analytics.

  Options: `:limit` — number of days to include (default 30).
  """
  def spending(%__MODULE__{} = w, opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)

    with {:ok, data} <- call_mock_or_http(w, fn pid ->
           MockRemit.do_spending(pid, w.address, opts)
         end, fn ->
           do_http_get(w, "/wallet/spending?days=#{limit}")
         end) do
      {:ok, SpendingSummary.from_map(data)}
    end
  end

  # ─── Payment Models ───────────────────────────────────────────────────────

  @doc """
  Send USDC directly to a recipient (pay-as-you-go).

  ## Parameters

  - `to` — 0x-prefixed recipient address
  - `amount_usdc` — amount as a string, e.g. `"1.50"`

  ## Options

  - `:description` — human-readable memo
  - `:metadata` — map of arbitrary key-value pairs

  ## Example

      {:ok, tx} = RemitMd.Wallet.pay(wallet, "0xRecipient", "1.50")
  """
  def pay(%__MODULE__{} = w, to, amount_usdc, opts \\ []) do
    with :ok <- validate_address(to),
         :ok <- validate_amount(amount_usdc) do
      nonce = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      body = %{
        to: to,
        amount: amount_usdc,
        task:   Keyword.get(opts, :description) || "",
        chain:  w.chain,
        nonce:  nonce,
        signature: "0x",
        metadata: Keyword.get(opts, :metadata)
      }
      body = maybe_add_permit(body, opts)

      with {:ok, data} <- call_mock_or_http(w, fn pid ->
             MockRemit.do_pay(pid, w.address, to, amount_usdc, opts)
           end, fn ->
             do_http_post(w, "/payments/direct", body)
           end) do
        {:ok, Transaction.from_map(data)}
      end
    end
  end

  @doc """
  Create an escrow payment with milestone-based release.

  ## Options

  - `:milestones` — list of milestone ID strings (default: `["complete"]`)
  - `:description` — task description
  - `:expires_in` — seconds until escrow expires (default: 7 days)

  ## Example

      {:ok, esc} = RemitMd.Wallet.create_escrow(wallet, "0xContractor", "50.00",
        milestones: ["design_approved", "code_reviewed", "deployed"])
  """
  def create_escrow(%__MODULE__{} = w, to, amount_usdc, opts \\ []) do
    with :ok <- validate_address(to),
         :ok <- validate_amount(amount_usdc) do
      milestones  = Keyword.get(opts, :milestones, ["complete"])
      description = Keyword.get(opts, :description)
      expires_in  = Keyword.get(opts, :expires_in, 7 * 86_400)

      body = %{
        to:          to,
        amount_usdc: amount_usdc,
        milestones:  milestones,
        description: description,
        expires_in:  expires_in
      }
      body = maybe_add_permit(body, opts)

      with {:ok, data} <- call_mock_or_http(w, fn pid ->
             MockRemit.do_create_escrow(pid, w.address, to, amount_usdc, opts)
           end, fn ->
             do_http_post(w, "/escrows", body)
           end) do
        {:ok, Escrow.from_map(data)}
      end
    end
  end

  @doc """
  Release an escrow milestone, transferring its share to the recipient.
  """
  def pay_milestone(%__MODULE__{} = w, escrow_id, milestone_id) do
    body = %{milestone_id: milestone_id}

    with {:ok, data} <- call_mock_or_http(w, fn pid ->
           MockRemit.do_pay_milestone(pid, w.address, escrow_id, milestone_id)
         end, fn ->
           do_http_post(w, "/escrows/#{escrow_id}/claim-start", body)
         end) do
      {:ok, Escrow.from_map(data)}
    end
  end

  @doc "Cancel an escrow and return funds to payer."
  def cancel_escrow(%__MODULE__{} = w, escrow_id) do
    with {:ok, data} <- call_mock_or_http(w, fn pid ->
           MockRemit.do_cancel_escrow(pid, w.address, escrow_id)
         end, fn ->
           do_http_post(w, "/escrows/#{escrow_id}/cancel", %{})
         end) do
      {:ok, Escrow.from_map(data)}
    end
  end

  @doc """
  Open an off-chain tab (batch payment channel).

  ## Options

  - `:credit_limit_usdc` — maximum balance before mandatory settlement
  - `:expires_in` — seconds until tab expires (default: 30 days)

  ## Example

      {:ok, tab} = RemitMd.Wallet.open_tab(wallet, "0xLLMProvider", "100.00")
  """
  def open_tab(%__MODULE__{} = w, to, credit_limit_usdc, opts \\ []) do
    with :ok <- validate_address(to),
         :ok <- validate_amount(credit_limit_usdc) do
      expires_in = Keyword.get(opts, :expires_in, 30 * 86_400)

      body = %{chain: w.chain, to: to, credit_limit_usdc: credit_limit_usdc, expires_in: expires_in}
      body = maybe_add_permit(body, opts)

      with {:ok, data} <- do_call(w, :post, "/tabs", body) do
        {:ok, Tab.from_map(data)}
      end
    end
  end

  @doc "Debit an open tab (off-chain micro-payment)."
  def debit_tab(%__MODULE__{} = w, tab_id, amount_usdc, opts \\ []) do
    with :ok <- validate_amount(amount_usdc) do
      body = %{amount_usdc: amount_usdc, description: Keyword.get(opts, :description)}

      with {:ok, data} <- do_call(w, :post, "/tabs/#{tab_id}/charge", body) do
        {:ok, data}
      end
    end
  end

  @doc "Settle a tab (triggers on-chain USDC transfer for the accumulated balance)."
  def settle_tab(%__MODULE__{} = w, tab_id) do
    with {:ok, data} <- do_call(w, :post, "/tabs/#{tab_id}/close", %{}) do
      {:ok, Tab.from_map(data)}
    end
  end

  @doc """
  Start a payment stream (continuous USDC flow per second).

  ## Options

  - `:duration` — stream duration in seconds

  ## Example

      {:ok, stream} = RemitMd.Wallet.create_stream(wallet, "0xWorker", "0.001",
        duration: 3_600)  # 1 hour at 0.001 USDC/s = 3.60 USDC total
  """
  def create_stream(%__MODULE__{} = w, to, rate_per_second_usdc, opts \\ []) do
    with :ok <- validate_address(to),
         :ok <- validate_amount(rate_per_second_usdc) do
      duration = Keyword.get(opts, :duration)
      body = %{chain: w.chain, to: to, rate_per_second_usdc: rate_per_second_usdc, duration: duration}
      body = maybe_add_permit(body, opts)

      with {:ok, data} <- do_call(w, :post, "/streams", body) do
        {:ok, Stream.from_map(data)}
      end
    end
  end

  @doc "Stop a running payment stream."
  def cancel_stream(%__MODULE__{} = w, stream_id) do
    with {:ok, data} <- do_call(w, :post, "/streams/#{stream_id}/close", %{}) do
      {:ok, Stream.from_map(data)}
    end
  end

  @doc """
  Post a bounty — any agent that completes the task earns the reward.

  ## Example

      {:ok, bounty} = RemitMd.Wallet.post_bounty(wallet, "10.00",
        description: "Summarize this 100-page PDF",
        expires_in: 3600)
  """
  def post_bounty(%__MODULE__{} = w, amount_usdc, opts \\ []) do
    with :ok <- validate_amount(amount_usdc) do
      body = %{
        chain:       w.chain,
        amount_usdc: amount_usdc,
        description: Keyword.get(opts, :description),
        expires_in:  Keyword.get(opts, :expires_in, 86_400)
      }
      body = maybe_add_permit(body, opts)

      with {:ok, data} <- do_call(w, :post, "/bounties", body) do
        {:ok, Bounty.from_map(data)}
      end
    end
  end

  @doc "Award a bounty to a specific winner."
  def award_bounty(%__MODULE__{} = w, bounty_id, winner_address) do
    with :ok <- validate_address(winner_address) do
      body = %{winner: winner_address}

      with {:ok, data} <- do_call(w, :post, "/bounties/#{bounty_id}/award", body) do
        {:ok, Bounty.from_map(data)}
      end
    end
  end

  @doc """
  List bounties with optional filters.

  ## Options

  - `:status` — filter by status (open, claimed, awarded, expired). Default: `"open"`.
  - `:poster` — filter by poster wallet address.
  - `:submitter` — filter by submitter wallet address.
  - `:limit` — max results (default 20, max 100).
  """
  def list_bounties(%__MODULE__{} = w, opts \\ []) do
    status    = Keyword.get(opts, :status, "open")
    poster    = Keyword.get(opts, :poster)
    submitter = Keyword.get(opts, :submitter)
    limit     = Keyword.get(opts, :limit, 20)

    params = ["limit=#{limit}"]
    params = if status,    do: ["status=#{status}" | params],    else: params
    params = if poster,    do: ["poster=#{poster}" | params],    else: params
    params = if submitter, do: ["submitter=#{submitter}" | params], else: params
    qs = Enum.join(Enum.reverse(params), "&")

    with {:ok, data} <- do_call(w, :get, "/bounties?#{qs}", nil) do
      items = if is_map(data) && Map.has_key?(data, "data"), do: data["data"], else: data
      bounties = Enum.map(items || [], &Bounty.from_map/1)
      {:ok, bounties}
    end
  end

  @doc """
  Register a webhook endpoint to receive event notifications.

  ## Parameters

  - `url` — the HTTPS endpoint that will receive POST notifications
  - `events` — list of event types to subscribe to (e.g. `["payment.sent", "escrow.funded"]`)

  ## Options

  - `:chains` — list of chain names to filter by (e.g. `["base"]`). Omit for all chains.

  ## Example

      {:ok, webhook} = RemitMd.Wallet.register_webhook(wallet,
        "https://example.com/webhooks",
        ["payment.sent", "escrow.funded"])
  """
  def register_webhook(%__MODULE__{} = w, url, events, opts \\ []) do
    chains = Keyword.get(opts, :chains)
    body = %{url: url, events: events}
    body = if chains, do: Map.put(body, :chains, chains), else: body

    with {:ok, data} <- do_call(w, :post, "/webhooks", body) do
      {:ok, Webhook.from_map(data)}
    end
  end

  @doc """
  Generate a one-time URL for the operator to fund this wallet.
  Returns `{:ok, %RemitMd.Models.LinkResponse{}}` or `{:error, %RemitMd.Error{}}`.
  """
  def create_fund_link(%__MODULE__{} = w) do
    with {:ok, data} <- do_call(w, :post, "/links/fund", %{}) do
      {:ok, RemitMd.Models.LinkResponse.from_map(data)}
    end
  end

  @doc """
  Generate a one-time URL for the operator to withdraw funds.
  Returns `{:ok, %RemitMd.Models.LinkResponse{}}` or `{:error, %RemitMd.Error{}}`.
  """
  def create_withdraw_link(%__MODULE__{} = w) do
    with {:ok, data} <- do_call(w, :post, "/links/withdraw", %{}) do
      {:ok, RemitMd.Models.LinkResponse.from_map(data)}
    end
  end

  # ─── Contracts ────────────────────────────────────────────────────────

  @doc """
  Fetch contract addresses for the current chain.
  Returns `{:ok, %RemitMd.Models.ContractAddresses{}}` or `{:error, %RemitMd.Error{}}`.
  """
  def get_contracts(%__MODULE__{} = w) do
    with {:ok, data} <- do_call(w, :get, "/contracts", nil) do
      {:ok, ContractAddresses.from_map(data)}
    end
  end

  # ─── Mint (testnet only) ─────────────────────────────────────────────

  @doc """
  Mint testnet USDC to this wallet (testnet only).

  ## Example

      {:ok, resp} = RemitMd.Wallet.mint(wallet, "100.00")
  """
  def mint(%__MODULE__{} = w, amount_usdc) do
    with :ok <- validate_amount(amount_usdc) do
      body = %{wallet: w.address, amount: amount_usdc}

      with {:ok, data} <- do_call(w, :post, "/mint", body) do
        {:ok, MintResponse.from_map(data)}
      end
    end
  end

  @doc false
  def inspect_address(%__MODULE__{address: addr}), do: addr

  # ─── Private ──────────────────────────────────────────────────────────────

  defp call_mock_or_http(%__MODULE__{mock_pid: nil}, _mock_fn, http_fn) do
    try do
      {:ok, http_fn.()}
    rescue
      e in RemitMd.Error -> {:error, e}
    end
  end

  defp call_mock_or_http(%__MODULE__{mock_pid: pid}, mock_fn, _http_fn) do
    case mock_fn.(pid) do
      {:ok, _} = ok  -> ok
      {:error, %RemitMd.Error{} = e} -> {:error, e}
      {:error, :not_found} ->
        {:error, RemitMd.Error.new(RemitMd.Error.not_found(), "Resource not found")}
      {:error, :forbidden} ->
        {:error, RemitMd.Error.new(RemitMd.Error.forbidden(), "Not authorized for this resource")}
      {:error, reason} ->
        {:error, RemitMd.Error.new(RemitMd.Error.server_error(), inspect(reason))}
    end
  end

  defp do_call(%__MODULE__{mock_pid: nil, transport: t}, method, path, body) do
    try do
      result =
        case method do
          :get  -> Http.get(t, path)
          :post -> Http.post(t, path, body)
        end
      {:ok, result}
    rescue
      e in RemitMd.Error -> {:error, e}
    end
  end

  defp do_call(%__MODULE__{mock_pid: _pid}, _method, _path, _body) do
    {:ok, %{}}  # Unimplemented mock endpoint — return empty map
  end

  defp do_http_get(%__MODULE__{transport: t}, path) do
    Http.get(t, path)
  end

  defp do_http_post(%__MODULE__{transport: t}, path, body) do
    Http.post(t, path, body)
  end

  defp validate_address(addr) when is_binary(addr) do
    if Regex.match?(~r/\A0x[0-9a-fA-F]{40}\z/, addr) do
      :ok
    else
      {:error,
       Error.new(Error.invalid_address(), "Invalid address: expected 0x + 40 hex chars, got #{inspect(addr)}")}
    end
  end

  defp validate_address(_), do: {:error, Error.new(Error.invalid_address(), "Address must be a string")}

  defp validate_amount(amount) when is_binary(amount) do
    try do
      d = Decimal.new(amount)

      if Decimal.compare(d, @min_amount) == :lt do
        {:error, Error.new(Error.invalid_amount(), "Amount #{amount} is below minimum 0.000001 USDC")}
      else
        :ok
      end
    rescue
      _ ->
        {:error, Error.new(Error.invalid_amount(), "Amount must be a valid decimal string, got #{inspect(amount)}")}
    end
  end

  defp validate_amount(_), do: {:error, Error.new(Error.invalid_amount(), "Amount must be a string")}

  defp get_address(%RemitMd.PrivateKeySigner{} = s), do: s.address
  defp get_address(%{address: addr}), do: addr
  defp get_address(%_{} = s), do: Map.get(s, :address)

  defp maybe_add_permit(body, opts) do
    case Keyword.get(opts, :permit) do
      %PermitSignature{} = p -> Map.put(body, :permit, PermitSignature.to_map(p))
      _ -> body
    end
  end

  # Strip testnet suffixes so we send "base" not "base_sepolia" in the pay body.
  defp base_chain_name(chain) do
    chain
    |> String.replace_suffix("_sepolia", "")
    |> String.replace_suffix("-sepolia", "")
  end
end
