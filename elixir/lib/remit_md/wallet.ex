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
    Balance, Bounty, BountySubmission, Budget, ContractAddresses, Deposit, Escrow,
    MintResponse, PermitSignature, Reputation, SpendingSummary, Stream, Tab, TabCharge,
    Transaction, TransactionList, Webhook
  }

  @min_amount Decimal.new("0.000001")

  # Known USDC contract addresses per chain (EIP-2612 compatible).
  @usdc_addresses %{
    "base-sepolia" => "0x2d846325766921935f37d5b4478196d3ef93707c",
    "base"         => "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    "localhost"    => "0x5FbDB2315678afecb367f032d93F642f64180aa3"
  }

  # Default JSON-RPC URLs per chain (for nonce fetching).
  @default_rpc_urls %{
    "base-sepolia" => "https://sepolia.base.org",
    "base"         => "https://mainnet.base.org",
    "localhost"    => "http://127.0.0.1:8545"
  }

  defstruct [:signer, :transport, :mock_pid, :address, :chain, :chain_key, :rpc_url]

  @type t :: %__MODULE__{
    signer:    term(),
    transport: term(),
    mock_pid:  pid() | nil,
    address:   String.t(),
    chain:     String.t() | nil,
    chain_key: String.t() | nil,
    rpc_url:   String.t() | nil
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
      %__MODULE__{
        signer: signer, transport: nil, mock_pid: mock_pid, address: signer.address,
        chain: "base", chain_key: "base-sepolia", rpc_url: @default_rpc_urls["base-sepolia"]
      }
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
      raw_chain = opts |> Keyword.get(:chain, "base")
      # chain_key preserves the full name for USDC/RPC lookups (e.g. "base_sepolia" → "base-sepolia")
      chain_key = raw_chain |> String.replace("_", "-")
      # Normalize to base chain name (strip testnet suffix) for use in pay body.
      # The server accepts "base" — not "base_sepolia" etc.
      chain = base_chain_name(raw_chain)
      rpc_url = Keyword.get(opts, :rpc_url)
        || System.get_env("REMITMD_RPC_URL")
        || @default_rpc_urls[chain_key]
        || @default_rpc_urls["base-sepolia"]
      %__MODULE__{
        signer: signer, transport: transport, mock_pid: nil, address: address,
        chain: chain, chain_key: chain_key, rpc_url: rpc_url
      }
    end
  end

  @doc """
  Build a wallet from environment variables.

  Required: `REMITMD_PRIVATE_KEY`
  Optional: `REMITMD_CHAIN`, `REMITMD_API_URL`, `REMITMD_ROUTER_ADDRESS`
  """
  def from_env do
    key = System.get_env("REMITMD_KEY") || System.get_env("REMITMD_PRIVATE_KEY")

    if System.get_env("REMITMD_PRIVATE_KEY") && !System.get_env("REMITMD_KEY") do
      IO.warn("REMITMD_PRIVATE_KEY is deprecated, use REMITMD_KEY instead")
    end

    key || raise Error.new(Error.unauthorized(), "REMITMD_KEY not set")

    chain          = System.get_env("REMITMD_CHAIN", "base")
    api_url        = System.get_env("REMITMD_API_URL")
    router_address = System.get_env("REMITMD_ROUTER_ADDRESS")
    rpc_url        = System.get_env("REMITMD_RPC_URL")

    opts = [private_key: key, chain: chain]
    opts = if api_url, do: Keyword.put(opts, :api_url, api_url), else: opts
    opts = if router_address, do: Keyword.put(opts, :router_address, router_address), else: opts
    opts = if rpc_url, do: Keyword.put(opts, :rpc_url, rpc_url), else: opts

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
      permit = resolve_permit(w, "router", amount_usdc, opts)
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
      body = if permit, do: Map.put(body, :permit, PermitSignature.to_map(permit)), else: body

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
      permit = resolve_permit(w, "escrow", amount_usdc, opts)
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
      body = if permit, do: Map.put(body, :permit, PermitSignature.to_map(permit)), else: body

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

  @doc "Provider claims start on an escrow (begins the escrow timer)."
  def claim_start(%__MODULE__{} = w, escrow_id) do
    with {:ok, data} <- do_call(w, :post, "/escrows/#{escrow_id}/claim-start", %{}) do
      {:ok, Escrow.from_map(data)}
    end
  end

  @doc "Release an escrow, transferring funds to the provider."
  def release_escrow(%__MODULE__{} = w, escrow_id) do
    with {:ok, data} <- do_call(w, :post, "/escrows/#{escrow_id}/release", %{}) do
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
  Create a metered tab (batch payment channel).

  ## Parameters

  - `provider` — 0x-prefixed provider address
  - `limit_amount` — maximum tab limit (string USDC, e.g. `"10.00"`)
  - `per_unit` — cost per unit/call (string USDC, e.g. `"0.10"`)

  ## Options

  - `:expires_in` — seconds from now until tab expires (default: 1 day)
  - `:permit` — `%PermitSignature{}` for gasless approval

  ## Example

      {:ok, tab} = RemitMd.Wallet.create_tab(wallet, "0xProvider", "10.00", "0.10")
  """
  def create_tab(%__MODULE__{} = w, provider, limit_amount, per_unit, opts \\ []) do
    with :ok <- validate_address(provider),
         :ok <- validate_amount(limit_amount) do
      permit = resolve_permit(w, "tab", limit_amount, opts)
      expires_in = Keyword.get(opts, :expires_in, 86_400)
      expiry = :os.system_time(:second) + expires_in

      body = %{
        chain: w.chain,
        provider: provider,
        limit_amount: limit_amount,
        per_unit: per_unit,
        expiry: expiry
      }
      body = if permit, do: Map.put(body, :permit, PermitSignature.to_map(permit)), else: body

      with {:ok, data} <- do_call(w, :post, "/tabs", body) do
        {:ok, Tab.from_map(data)}
      end
    end
  end

  @doc """
  Charge a tab with an EIP-712 TabCharge signature (provider-side).

  ## Parameters

  - `tab_id` — tab UUID
  - `amount` — charge amount (number)
  - `cumulative` — cumulative total charged so far (number)
  - `call_count` — total number of charges (integer)
  - `provider_sig` — EIP-712 TabCharge signature from `sign_tab_charge/4`
  """
  def charge_tab(%__MODULE__{} = w, tab_id, amount, cumulative, call_count, provider_sig) do
    body = %{
      amount: amount,
      cumulative: cumulative,
      call_count: call_count,
      provider_sig: provider_sig
    }

    with {:ok, data} <- do_call(w, :post, "/tabs/#{tab_id}/charge", body) do
      {:ok, TabCharge.from_map(data)}
    end
  end

  @doc """
  Close a tab with final settlement.

  ## Options

  - `:final_amount` — final settlement amount (number, default 0)
  - `:provider_sig` — provider's EIP-712 signature (default "0x")
  """
  def close_tab(%__MODULE__{} = w, tab_id, opts \\ []) do
    final_amount = Keyword.get(opts, :final_amount, 0)
    provider_sig = Keyword.get(opts, :provider_sig, "0x")

    body = %{final_amount: final_amount, provider_sig: provider_sig}

    with {:ok, data} <- do_call(w, :post, "/tabs/#{tab_id}/close", body) do
      {:ok, Tab.from_map(data)}
    end
  end

  @doc """
  Sign a TabCharge EIP-712 message (provider-side).

  ## Parameters

  - `tab_contract` — Tab contract address (verifyingContract for the domain)
  - `tab_id` — UUID of the tab (will be encoded as bytes32)
  - `total_charged` — cumulative charged amount in USDC base units (integer, uint96)
  - `call_count` — number of charges made (integer, uint32)

  Returns a 0x-prefixed hex signature.
  """
  def sign_tab_charge(%__MODULE__{} = w, tab_contract, tab_id, total_charged, call_count) do
    keccak = &RemitMd.Keccak.hash/1

    # Domain separator: RemitTab
    domain_type_hash =
      keccak.("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")

    name_hash = keccak.("RemitTab")
    version_hash = keccak.("1")
    chain_id_enc = <<chain_id(w)::unsigned-big-integer-size(256)>>
    contract_enc = address_to_bytes32(tab_contract)

    domain_separator =
      keccak.(domain_type_hash <> name_hash <> version_hash <> chain_id_enc <> contract_enc)

    # Struct hash: TabCharge(bytes32 tabId, uint96 totalCharged, uint32 callCount)
    tab_charge_type_hash =
      keccak.("TabCharge(bytes32 tabId,uint96 totalCharged,uint32 callCount)")

    # Encode tab_id as bytes32: ASCII chars padded to 32 bytes
    tab_id_bytes = String.slice(tab_id, 0, 32)
    padded = tab_id_bytes <> :binary.copy(<<0>>, 32 - byte_size(tab_id_bytes))

    total_enc = <<total_charged::unsigned-big-integer-size(256)>>
    count_enc = <<call_count::unsigned-big-integer-size(256)>>

    struct_hash = keccak.(tab_charge_type_hash <> padded <> total_enc <> count_enc)

    # Final: keccak256(0x1901 || domainSeparator || structHash)
    digest = keccak.(<<0x19, 0x01>> <> domain_separator <> struct_hash)

    call_sign(w.signer, digest)
  end

  # ─── EIP-2612 Permit ─────────────────────────────────────────────────

  @doc """
  Sign an EIP-2612 permit for USDC approval.

  Domain: name="USD Coin", version="2", chainId, verifyingContract=USDC address
  Type: Permit(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)

  ## Parameters

  - `spender` — contract address that will be approved as spender
  - `value` — amount in USDC base units (6 decimals, integer)
  - `deadline` — permit deadline (Unix timestamp)

  ## Options

  - `:nonce` — current permit nonce for this wallet (default: 0)
  - `:usdc_address` — override the USDC contract address

  Returns `%PermitSignature{}`.
  """
  def sign_usdc_permit(%__MODULE__{} = w, spender, value, deadline, opts \\ []) do
    keccak = &RemitMd.Keccak.hash/1

    nonce = Keyword.get(opts, :nonce, 0)
    usdc_addr = Keyword.get(opts, :usdc_address) || @usdc_addresses[w.chain_key] || ""

    # Domain separator for USDC (EIP-2612)
    domain_type_hash =
      keccak.("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")

    name_hash = keccak.("USD Coin")
    version_hash = keccak.("2")
    chain_id_enc = <<chain_id(w)::unsigned-big-integer-size(256)>>
    contract_enc = address_to_bytes32(usdc_addr)

    domain_separator =
      keccak.(domain_type_hash <> name_hash <> version_hash <> chain_id_enc <> contract_enc)

    # Permit struct hash
    permit_type_hash =
      keccak.("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")

    owner_enc    = address_to_bytes32(w.address)
    spender_enc  = address_to_bytes32(spender)
    value_enc    = <<value::unsigned-big-integer-size(256)>>
    nonce_enc    = <<nonce::unsigned-big-integer-size(256)>>
    deadline_enc = <<deadline::unsigned-big-integer-size(256)>>

    struct_hash =
      keccak.(permit_type_hash <> owner_enc <> spender_enc <> value_enc <> nonce_enc <> deadline_enc)

    # Final: keccak256(0x1901 || domainSeparator || structHash)
    digest = keccak.(<<0x19, 0x01>> <> domain_separator <> struct_hash)

    sig_hex = call_sign(w.signer, digest)

    # Parse r, s, v from the 65-byte signature
    sig_str = String.trim_leading(sig_hex, "0x")
    r = "0x" <> String.slice(sig_str, 0, 64)
    s = "0x" <> String.slice(sig_str, 64, 64)
    v = String.slice(sig_str, 128, 2) |> String.to_integer(16)

    %PermitSignature{value: value, deadline: deadline, v: v, r: r, s: s}
  end

  @doc """
  Convenience: sign an EIP-2612 permit for USDC approval.
  Auto-fetches the on-chain nonce and sets a default deadline (1 hour from now).

  ## Parameters

  - `spender` — contract address to approve (e.g. router, escrow)
  - `amount` — amount in USDC (string, e.g. `"5.00"`)

  ## Options

  - `:deadline` — optional Unix timestamp; defaults to 1 hour from now

  Returns `%PermitSignature{}`.
  """
  def sign_permit(%__MODULE__{} = w, spender, amount, opts \\ []) do
    usdc_addr = @usdc_addresses[w.chain_key] || ""
    nonce = fetch_usdc_nonce(w, usdc_addr)
    deadline = Keyword.get(opts, :deadline) || (:os.system_time(:second) + 3600)
    raw = amount |> to_string() |> Decimal.new() |> Decimal.mult(1_000_000) |> Decimal.round(0) |> Decimal.to_integer()
    sign_usdc_permit(w, spender, raw, deadline, nonce: nonce, usdc_address: usdc_addr)
  end

  @doc """
  Start a payment stream (continuous USDC flow per second).

  ## Parameters

  - `payee` — 0x-prefixed recipient address
  - `rate_per_second` — USDC per second (string, e.g. `"0.01"`)
  - `max_total` — maximum total USDC for the stream (string, e.g. `"5.00"`)

  ## Options

  - `:permit` — `%PermitSignature{}` for gasless approval

  ## Example

      {:ok, stream} = RemitMd.Wallet.create_stream(wallet, "0xWorker", "0.01", "5.00")
  """
  def create_stream(%__MODULE__{} = w, payee, rate_per_second, max_total, opts \\ []) do
    with :ok <- validate_address(payee) do
      permit = resolve_permit(w, "stream", max_total, opts)
      body = %{
        chain: w.chain,
        payee: payee,
        rate_per_second: rate_per_second,
        max_total: max_total
      }
      body = if permit, do: Map.put(body, :permit, PermitSignature.to_map(permit)), else: body

      with {:ok, data} <- do_call(w, :post, "/streams", body) do
        {:ok, Stream.from_map(data)}
      end
    end
  end

  @doc "Close a running payment stream."
  def close_stream(%__MODULE__{} = w, stream_id) do
    with {:ok, data} <- do_call(w, :post, "/streams/#{stream_id}/close", %{}) do
      {:ok, Stream.from_map(data)}
    end
  end

  @doc """
  Create a bounty — any agent that completes the task earns the reward.

  ## Parameters

  - `amount` — reward amount (string USDC, e.g. `"5.00"`)
  - `task_description` — description of the task
  - `deadline` — unix timestamp when the bounty expires

  ## Options

  - `:max_attempts` — maximum number of submissions (default: 10)
  - `:permit` — `%PermitSignature{}` for gasless approval

  ## Example

      deadline = :os.system_time(:second) + 3600
      {:ok, bounty} = RemitMd.Wallet.create_bounty(wallet, "10.00",
        "Summarize this 100-page PDF", deadline)
  """
  def create_bounty(%__MODULE__{} = w, amount, task_description, deadline, opts \\ []) do
    with :ok <- validate_amount(amount) do
      permit = resolve_permit(w, "bounty", amount, opts)
      body = %{
        chain:            w.chain,
        amount:           amount,
        task_description: task_description,
        deadline:         deadline,
        max_attempts:     Keyword.get(opts, :max_attempts, 10)
      }
      body = if permit, do: Map.put(body, :permit, PermitSignature.to_map(permit)), else: body

      with {:ok, data} <- do_call(w, :post, "/bounties", body) do
        {:ok, Bounty.from_map(data)}
      end
    end
  end

  @doc """
  Submit evidence for a bounty.

  ## Parameters

  - `bounty_id` — bounty UUID
  - `evidence_hash` — 0x-prefixed keccak256 hash of the evidence

  Returns `{:ok, %BountySubmission{}}`.
  """
  def submit_bounty(%__MODULE__{} = w, bounty_id, evidence_hash) do
    body = %{evidence_hash: evidence_hash}

    with {:ok, data} <- do_call(w, :post, "/bounties/#{bounty_id}/submit", body) do
      {:ok, BountySubmission.from_map(data)}
    end
  end

  @doc """
  Award a bounty to a specific submission.

  ## Parameters

  - `bounty_id` — bounty UUID
  - `submission_id` — integer ID of the winning submission
  """
  def award_bounty(%__MODULE__{} = w, bounty_id, submission_id) when is_integer(submission_id) do
    body = %{submission_id: submission_id}

    with {:ok, data} <- do_call(w, :post, "/bounties/#{bounty_id}/award", body) do
      {:ok, Bounty.from_map(data)}
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

  ## Options

  - `:messages` — list of maps with `:role` ("agent"/"system") and `:text`
  - `:agent_name` — agent display name shown on the funding page
  - `:permit` — `%PermitSignature{}` for gasless approval (auto-signed if omitted)

  Returns `{:ok, %RemitMd.Models.LinkResponse{}}` or `{:error, %RemitMd.Error{}}`.
  """
  def create_fund_link(%__MODULE__{} = w, opts \\ []) do
    permit = resolve_permit(w, "relayer", "999999999.0", opts)
    body = build_link_body(opts)
    body = if permit, do: Map.put(body, :permit, PermitSignature.to_map(permit)), else: body
    with {:ok, data} <- do_call(w, :post, "/links/fund", body) do
      {:ok, RemitMd.Models.LinkResponse.from_map(data)}
    end
  end

  @doc """
  Generate a one-time URL for the operator to withdraw funds.

  ## Options

  - `:messages` — list of maps with `:role` ("agent"/"system") and `:text`
  - `:agent_name` — agent display name shown on the withdraw page
  - `:permit` — `%PermitSignature{}` for gasless approval (auto-signed if omitted)

  Returns `{:ok, %RemitMd.Models.LinkResponse{}}` or `{:error, %RemitMd.Error{}}`.
  """
  def create_withdraw_link(%__MODULE__{} = w, opts \\ []) do
    permit = resolve_permit(w, "relayer", "999999999.0", opts)
    body = build_link_body(opts)
    body = if permit, do: Map.put(body, :permit, PermitSignature.to_map(permit)), else: body
    with {:ok, data} <- do_call(w, :post, "/links/withdraw", body) do
      {:ok, RemitMd.Models.LinkResponse.from_map(data)}
    end
  end

  # ─── Deposits ─────────────────────────────────────────────────────────

  @doc """
  Place a refundable deposit with a provider.

  ## Parameters

  - `provider` — 0x-prefixed provider address
  - `amount` — deposit amount (string USDC, e.g. `"5.00"`)

  ## Options

  - `:expires_in` — seconds from now until deposit expires (default: 1 hour)
  - `:permit` — `%PermitSignature{}` for gasless approval

  ## Example

      {:ok, dep} = RemitMd.Wallet.place_deposit(wallet, "0xProvider", "5.00")
  """
  def place_deposit(%__MODULE__{} = w, provider, amount, opts \\ []) do
    with :ok <- validate_address(provider),
         :ok <- validate_amount(amount) do
      permit = resolve_permit(w, "deposit", amount, opts)
      expires_in = Keyword.get(opts, :expires_in, 3600)
      expiry = :os.system_time(:second) + expires_in

      body = %{
        chain:    w.chain,
        provider: provider,
        amount:   amount,
        expiry:   expiry
      }
      body = if permit, do: Map.put(body, :permit, PermitSignature.to_map(permit)), else: body

      with {:ok, data} <- do_call(w, :post, "/deposits", body) do
        {:ok, Deposit.from_map(data)}
      end
    end
  end

  @doc """
  Return a deposit (provider-side). Full refund to depositor, no fee.
  """
  def return_deposit(%__MODULE__{} = w, deposit_id) do
    with {:ok, data} <- do_call(w, :post, "/deposits/#{deposit_id}/return", %{}) do
      {:ok, Deposit.from_map(data)}
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

  # Resolve permit: use explicit from opts, or auto-sign. Returns PermitSignature or nil (mock mode).
  defp resolve_permit(%__MODULE__{mock_pid: pid}, _contract, _amount, _opts) when pid != nil, do: nil

  defp resolve_permit(%__MODULE__{} = w, contract, amount, opts) do
    case Keyword.get(opts, :permit) do
      %PermitSignature{} = p -> p
      _ -> auto_permit(w, contract, amount)
    end
  end

  # ─── Permit helpers ──────────────────────────────────────────────

  # Auto-sign a permit for the given contract type and amount.
  # Used by payment methods when no explicit permit is provided.
  defp auto_permit(%__MODULE__{} = w, contract, amount) do
    {:ok, contracts} = get_contracts(w)
    spender = Map.get(contracts, String.to_existing_atom(contract))

    unless spender do
      raise Error.new(Error.server_error(), "No #{contract} contract address available")
    end

    sign_permit(w, spender, amount)
  end

  # Fetch the current EIP-2612 nonce for this wallet from the USDC contract via JSON-RPC.
  # Uses eth_call with selector 0x7ecebe00 (nonces(address)).
  defp fetch_usdc_nonce(%__MODULE__{mock_pid: pid}, _usdc_address) when pid != nil, do: 0

  defp fetch_usdc_nonce(%__MODULE__{} = w, usdc_address) do
    padded = w.address |> String.downcase() |> String.trim_leading("0x") |> String.pad_leading(64, "0")
    data = "0x7ecebe00#{padded}"

    payload = Jason.encode!(%{
      jsonrpc: "2.0",
      id: 1,
      method: "eth_call",
      params: [%{to: usdc_address, data: data}, "latest"]
    })

    url = w.rpc_url |> String.to_charlist()
    headers = [{~c"content-type", ~c"application/json"}]
    body_charlist = String.to_charlist(payload)

    case :httpc.request(:post, {url, headers, ~c"application/json", body_charlist},
           [timeout: 10_000, connect_timeout: 5_000], []) do
      {:ok, {{_version, _status, _reason}, _resp_headers, resp_body}} ->
        result = Jason.decode!(to_string(resp_body))

        if result["error"] do
          msg = if is_map(result["error"]), do: result["error"]["message"], else: inspect(result["error"])
          raise Error.new(Error.network_error(), "RPC error fetching nonce: #{msg}")
        end

        (result["result"] || "0x0")
        |> String.trim_leading("0x")
        |> String.to_integer(16)

      {:error, reason} ->
        raise Error.new(Error.network_error(), "Network error fetching nonce: #{inspect(reason)}")
    end
  end

  # Build a body map for create_fund_link / create_withdraw_link from keyword opts.
  defp build_link_body(opts) do
    body = %{}
    body = case Keyword.get(opts, :messages) do
      nil -> body
      msgs -> Map.put(body, :messages, msgs)
    end
    case Keyword.get(opts, :agent_name) do
      nil -> body
      name -> Map.put(body, :agent_name, name)
    end
  end

  # Strip testnet suffixes so we send "base" not "base_sepolia" in the pay body.
  defp base_chain_name(chain) do
    chain
    |> String.replace_suffix("_sepolia", "")
    |> String.replace_suffix("-sepolia", "")
  end

  # Return the numeric chain ID for EIP-712 signing.
  defp chain_id(%__MODULE__{transport: %Http{chain_id: id}}), do: id
  defp chain_id(%__MODULE__{chain: "base"}), do: 8453
  defp chain_id(%__MODULE__{chain: "base_sepolia"}), do: 84532
  defp chain_id(_), do: 84532

  defp address_to_bytes32(nil), do: <<0::256>>
  defp address_to_bytes32(""), do: <<0::256>>
  defp address_to_bytes32(address) do
    hex = String.trim_leading(address, "0x")
    if String.length(hex) == 40 do
      addr_bytes = Base.decode16!(hex, case: :mixed)
      :binary.copy(<<0>>, 12) <> addr_bytes
    else
      <<0::256>>
    end
  end

  defp call_sign(%{__struct__: mod} = signer, digest) do
    mod.sign(signer, digest)
  end
end
