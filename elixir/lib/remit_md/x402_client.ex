defmodule RemitMd.X402Client do
  @moduledoc """
  x402 client middleware for auto-paying HTTP 402 Payment Required responses.

  x402 is an open payment standard where resource servers return HTTP 402 with
  a `PAYMENT-REQUIRED` header describing the cost. This module provides a
  `fetch/3` function that intercepts those responses, signs an EIP-3009
  authorization, and retries the request with a `PAYMENT-SIGNATURE` header.

  ## Example

      signer = RemitMd.PrivateKeySigner.new("0x...")
      {:ok, {status, headers, body}} = RemitMd.X402Client.fetch(
        signer, "0xYourAddress",
        "https://api.provider.com/v1/data",
        max_auto_pay_usdc: 0.10
      )
  """

  @eip3009_type_hash "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"

  defmodule AllowanceExceededError do
    @moduledoc "Raised when an x402 payment amount exceeds the configured auto-pay limit."
    defexception [:amount_usdc, :limit_usdc, :message]

    @impl true
    def exception(opts) do
      amount = Keyword.fetch!(opts, :amount_usdc)
      limit = Keyword.fetch!(opts, :limit_usdc)
      msg = "x402 payment #{:erlang.float_to_binary(amount, decimals: 6)} USDC exceeds auto-pay limit #{:erlang.float_to_binary(limit, decimals: 6)} USDC"
      %__MODULE__{amount_usdc: amount, limit_usdc: limit, message: msg}
    end
  end

  @type payment_required :: %{
    scheme: String.t(),
    network: String.t(),
    amount: String.t(),
    asset: String.t(),
    pay_to: String.t(),
    max_timeout_seconds: integer() | nil,
    resource: String.t() | nil,
    description: String.t() | nil,
    mime_type: String.t() | nil
  }

  @doc """
  Make an HTTP request, auto-paying any 402 responses within the configured limit.

  ## Parameters

  - `signer` - a signer struct implementing `RemitMd.Signer` behaviour
  - `address` - checksummed payer address matching the signer
  - `url` - the URL to fetch

  ## Options

  - `:max_auto_pay_usdc` - maximum USDC amount to auto-pay per request (default: 0.10)
  - `:method` - HTTP method (default: `:get`)
  - `:body` - request body (for POST requests)
  - `:headers` - additional request headers (list of `{key, value}` charlists)

  Returns `{:ok, {status_code, response_headers, response_body}}` or `{:error, reason}`.
  """
  @spec fetch(term(), String.t(), String.t(), keyword()) ::
    {:ok, {integer(), list(), String.t()}} | {:error, term()}
  def fetch(signer, address, url, opts \\ []) do
    :inets.start()
    :ssl.start()

    max_auto_pay = Keyword.get(opts, :max_auto_pay_usdc, 0.10)
    method = Keyword.get(opts, :method, :get)
    body = Keyword.get(opts, :body)
    extra_headers = Keyword.get(opts, :headers, [])

    case do_request(method, url, body, extra_headers) do
      {:ok, {402, resp_headers, _resp_body}} ->
        handle_402(signer, address, url, method, body, extra_headers, resp_headers, max_auto_pay)

      {:ok, {status, resp_headers, resp_body}} ->
        {:ok, {status, resp_headers, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp handle_402(signer, address, url, method, body, extra_headers, resp_headers, max_auto_pay) do
    # 1. Decode PAYMENT-REQUIRED header (case-insensitive lookup)
    raw = find_header(resp_headers, "payment-required")

    unless raw do
      raise "402 response missing PAYMENT-REQUIRED header"
    end

    required = raw |> Base.decode64!() |> Jason.decode!()

    # 2. Only "exact" scheme is supported
    scheme = Map.get(required, "scheme", "")
    unless scheme == "exact" do
      raise "Unsupported x402 scheme: #{scheme}"
    end

    # 3. Check auto-pay limit
    amount_base_units = String.to_integer(Map.fetch!(required, "amount"))
    amount_usdc = amount_base_units / 1_000_000

    if amount_usdc > max_auto_pay do
      raise AllowanceExceededError, amount_usdc: amount_usdc, limit_usdc: max_auto_pay
    end

    # 4. Parse chainId from CAIP-2 network string (e.g. "eip155:84532")
    network = Map.fetch!(required, "network")
    chain_id = network |> String.split(":") |> List.last() |> String.to_integer()

    # 5. Build EIP-3009 authorization
    now_secs = :os.system_time(:second)
    max_timeout = Map.get(required, "maxTimeoutSeconds", 60)
    valid_before = now_secs + max_timeout
    nonce_bytes = :crypto.strong_rand_bytes(32)
    nonce_hex = "0x" <> Base.encode16(nonce_bytes, case: :lower)

    asset = Map.fetch!(required, "asset")
    pay_to = Map.fetch!(required, "payTo")

    # 6. Sign EIP-712 typed data for TransferWithAuthorization
    keccak = &RemitMd.Keccak.hash/1

    domain_type_hash =
      keccak.("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")

    name_hash = keccak.("USD Coin")
    version_hash = keccak.("2")
    chain_id_enc = <<chain_id::unsigned-big-integer-size(256)>>
    contract_enc = address_to_bytes32(asset)

    domain_separator =
      keccak.(domain_type_hash <> name_hash <> version_hash <> chain_id_enc <> contract_enc)

    transfer_type_hash = keccak.(@eip3009_type_hash)

    from_enc = address_to_bytes32(address)
    to_enc = address_to_bytes32(pay_to)
    value_enc = <<amount_base_units::unsigned-big-integer-size(256)>>
    valid_after_enc = <<0::unsigned-big-integer-size(256)>>
    valid_before_enc = <<valid_before::unsigned-big-integer-size(256)>>

    struct_hash =
      keccak.(transfer_type_hash <> from_enc <> to_enc <> value_enc <>
              valid_after_enc <> valid_before_enc <> nonce_bytes)

    digest = keccak.(<<0x19, 0x01>> <> domain_separator <> struct_hash)

    signature = call_sign(signer, digest)

    # 7. Build PAYMENT-SIGNATURE JSON payload
    payment_payload = %{
      scheme: scheme,
      network: network,
      x402Version: 1,
      payload: %{
        signature: signature,
        authorization: %{
          from: address,
          to: pay_to,
          value: Map.fetch!(required, "amount"),
          validAfter: "0",
          validBefore: to_string(valid_before),
          nonce: nonce_hex
        }
      }
    }

    payment_header = payment_payload |> Jason.encode!() |> Base.encode64()

    # 8. Retry with PAYMENT-SIGNATURE header
    payment_headers = [{~c"PAYMENT-SIGNATURE", String.to_charlist(payment_header)} | extra_headers]
    do_request(method, url, body, payment_headers)
  end

  defp do_request(method, url, body, extra_headers) do
    url_charlist = String.to_charlist(url)
    headers = extra_headers

    result =
      case method do
        :get ->
          :httpc.request(:get, {url_charlist, headers}, [{:timeout, 10_000}], [])

        :post ->
          body_str = if body, do: String.to_charlist(body), else: ~c""
          post_headers = [{~c"content-type", ~c"application/json"} | headers]
          :httpc.request(:post, {url_charlist, post_headers, ~c"application/json", body_str},
                        [{:timeout, 10_000}], [])
      end

    case result do
      {:ok, {{_ver, status, _reason}, resp_headers, resp_body}} ->
        {:ok, {status, resp_headers, to_string(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_header(headers, target_name) do
    target_lower = String.downcase(target_name)
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(to_string(name)) == target_lower do
        to_string(value)
      end
    end)
  end

  defp address_to_bytes32(address) do
    hex = String.trim_leading(address, "0x")
    addr_bytes = Base.decode16!(hex, case: :mixed)
    :binary.copy(<<0>>, 12) <> addr_bytes
  end

  defp call_sign(%{__struct__: mod} = signer, digest) do
    mod.sign(signer, digest)
  end
end
