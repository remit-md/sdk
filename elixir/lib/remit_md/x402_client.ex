defmodule RemitMd.X402Client do
  @moduledoc """
  x402 client middleware for auto-paying HTTP 402 Payment Required responses.

  x402 is an open payment standard where resource servers return HTTP 402 with
  a `PAYMENT-REQUIRED` header describing the cost. This module provides a
  `fetch/3` function that intercepts those responses, calls the server's
  `/x402/prepare` endpoint for hash + authorization fields, signs the hash,
  and retries the request with a `PAYMENT-SIGNATURE` header.

  ## Example

      signer = RemitMd.PrivateKeySigner.new("0x...")
      {:ok, {status, headers, body}} = RemitMd.X402Client.fetch(
        signer, "0xYourAddress",
        "https://api.provider.com/v1/data",
        max_auto_pay_usdc: 0.10,
        api_url: "https://remit.md"
      )
  """

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
  - `:api_url` - base URL of the remit.md API (default: `"https://remit.md"`)

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
    api_url = Keyword.get(opts, :api_url, "https://remit.md") |> String.trim_trailing("/")

    case do_request(method, url, body, extra_headers) do
      {:ok, {402, resp_headers, _resp_body}} ->
        handle_402(signer, address, url, method, body, extra_headers, resp_headers, max_auto_pay, api_url)

      {:ok, {status, resp_headers, resp_body}} ->
        {:ok, {status, resp_headers, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp handle_402(signer, address, url, method, body, extra_headers, resp_headers, max_auto_pay, api_url) do
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

    # 4. Call /x402/prepare to get the hash + authorization fields
    prepare_url = String.to_charlist("#{api_url}/api/v1/x402/prepare")
    prepare_body = Jason.encode!(%{payment_required: raw, payer: address})
    prepare_headers = [{~c"content-type", ~c"application/json"}]

    {:ok, {{_ver, prepare_status, _reason}, _prep_headers, prep_body}} =
      :httpc.request(:post, {prepare_url, prepare_headers, ~c"application/json",
                     String.to_charlist(prepare_body)}, [{:timeout, 10_000}], [])

    unless prepare_status in 200..299 do
      raise "x402/prepare failed with status #{prepare_status}: #{to_string(prep_body)}"
    end

    prepare_data = Jason.decode!(to_string(prep_body))

    # 5. Sign the hash
    hash_hex = Map.fetch!(prepare_data, "hash")
    hash_bytes = hash_hex |> String.trim_leading("0x") |> Base.decode16!(case: :mixed)
    signature = call_sign_hash(signer, hash_bytes)

    # 6. Build PAYMENT-SIGNATURE JSON payload
    network = Map.fetch!(required, "network")

    payment_payload = %{
      scheme: scheme,
      network: network,
      x402Version: 1,
      payload: %{
        signature: signature,
        authorization: %{
          from: prepare_data["from"],
          to: prepare_data["to"],
          value: prepare_data["value"],
          validAfter: prepare_data["valid_after"] || prepare_data["validAfter"],
          validBefore: prepare_data["valid_before"] || prepare_data["validBefore"],
          nonce: prepare_data["nonce"]
        }
      }
    }

    payment_header = payment_payload |> Jason.encode!() |> Base.encode64()

    # 7. Retry with PAYMENT-SIGNATURE header
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

  defp call_sign_hash(%{__struct__: mod} = signer, hash) do
    mod.sign_hash(signer, hash)
  end
end
