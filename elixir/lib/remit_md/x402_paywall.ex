defmodule RemitMd.X402Paywall do
  @moduledoc """
  x402 service provider middleware for gating HTTP endpoints behind payments.

  Providers use this module to:
  - Return HTTP 402 responses with properly formatted `PAYMENT-REQUIRED` headers
  - Verify incoming `PAYMENT-SIGNATURE` headers against the remit.md facilitator

  ## Example

      paywall = RemitMd.X402Paywall.new(
        wallet_address: "0xYourProviderWallet",
        amount_usdc: 0.001,
        network: "eip155:84532",
        asset: "0x2d846325766921935f37d5b4478196d3ef93707c"
      )

      header = RemitMd.X402Paywall.payment_required_header(paywall)
      # Use header in a 402 response

      {:ok, result} = RemitMd.X402Paywall.check(paywall, payment_sig)
      # result.is_valid == true or false

  ## Plug Middleware

  Use `RemitMd.X402Paywall.Plug` in your Plug/Phoenix pipeline:

      plug RemitMd.X402Paywall.Plug, paywall: paywall
  """

  @enforce_keys [:wallet_address, :amount_base_units, :network, :asset]
  defstruct [
    :wallet_address,
    :amount_base_units,
    :network,
    :asset,
    facilitator_url: "https://remit.md",
    facilitator_token: "",
    max_timeout_seconds: 60,
    resource: nil,
    description: nil,
    mime_type: nil
  ]

  @type t :: %__MODULE__{
    wallet_address: String.t(),
    amount_base_units: String.t(),
    network: String.t(),
    asset: String.t(),
    facilitator_url: String.t(),
    facilitator_token: String.t(),
    max_timeout_seconds: integer(),
    resource: String.t() | nil,
    description: String.t() | nil,
    mime_type: String.t() | nil
  }

  @type check_result :: %{is_valid: boolean(), invalid_reason: String.t() | nil}

  @doc """
  Create a new X402Paywall.

  ## Options

  - `:wallet_address` - provider's checksummed Ethereum address (required)
  - `:amount_usdc` - price per request in USDC, e.g. `0.001` (required)
  - `:network` - CAIP-2 network string, e.g. `"eip155:84532"` (required)
  - `:asset` - USDC contract address on the target network (required)
  - `:facilitator_url` - base URL of the remit.md facilitator (default: `"https://remit.md"`)
  - `:facilitator_token` - bearer JWT for `/api/v1/x402/verify` (default: `""`)
  - `:max_timeout_seconds` - payment authorization validity in seconds (default: 60)
  - `:resource` - URL or path of the resource being protected
  - `:description` - human-readable description of what the payment is for
  - `:mime_type` - MIME type of the resource
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    wallet_address = Keyword.fetch!(opts, :wallet_address)
    amount_usdc = Keyword.fetch!(opts, :amount_usdc)
    network = Keyword.fetch!(opts, :network)
    asset = Keyword.fetch!(opts, :asset)

    amount_base_units = amount_usdc |> Kernel.*(1_000_000) |> round() |> to_string()

    %__MODULE__{
      wallet_address: wallet_address,
      amount_base_units: amount_base_units,
      network: network,
      asset: asset,
      facilitator_url: Keyword.get(opts, :facilitator_url, "https://remit.md") |> String.trim_trailing("/"),
      facilitator_token: Keyword.get(opts, :facilitator_token, ""),
      max_timeout_seconds: Keyword.get(opts, :max_timeout_seconds, 60),
      resource: Keyword.get(opts, :resource),
      description: Keyword.get(opts, :description),
      mime_type: Keyword.get(opts, :mime_type)
    }
  end

  @doc """
  Return the base64-encoded JSON `PAYMENT-REQUIRED` header value.
  """
  @spec payment_required_header(t()) :: String.t()
  def payment_required_header(%__MODULE__{} = pw) do
    payload = payment_required_object(pw)
    payload |> Jason.encode!() |> Base.encode64()
  end

  @doc """
  Check whether a `PAYMENT-SIGNATURE` header represents a valid payment.

  Calls the remit.md facilitator's `/api/v1/x402/verify` endpoint.

  Returns `{:ok, %{is_valid: boolean(), invalid_reason: String.t() | nil}}`.
  """
  @spec check(t(), String.t() | nil) :: {:ok, check_result()}
  def check(_pw, nil), do: {:ok, %{is_valid: false, invalid_reason: nil}}

  def check(%__MODULE__{} = pw, payment_sig) when is_binary(payment_sig) do
    :inets.start()
    :ssl.start()

    payment_payload =
      case Base.decode64(payment_sig) do
        {:ok, decoded} ->
          case Jason.decode(decoded) do
            {:ok, data} -> data
            {:error, _} -> nil
          end
        :error -> nil
      end

    unless payment_payload do
      {:ok, %{is_valid: false, invalid_reason: "INVALID_PAYLOAD"}}
    else
      body = Jason.encode!(%{
        paymentPayload: payment_payload,
        paymentRequired: payment_required_object(pw)
      })

      url = String.to_charlist("#{pw.facilitator_url}/api/v1/x402/verify")

      headers = [{~c"content-type", ~c"application/json"}]
      headers =
        if pw.facilitator_token != "" do
          [{~c"authorization", String.to_charlist("Bearer #{pw.facilitator_token}")} | headers]
        else
          headers
        end

      case :httpc.request(:post, {url, headers, ~c"application/json", String.to_charlist(body)},
                          [{:timeout, 10_000}], []) do
        {:ok, {{_ver, status, _reason}, _resp_headers, resp_body}} when status in 200..299 ->
          case Jason.decode(to_string(resp_body)) do
            {:ok, %{"isValid" => true}} ->
              {:ok, %{is_valid: true, invalid_reason: nil}}

            {:ok, data} ->
              {:ok, %{is_valid: false, invalid_reason: Map.get(data, "invalidReason")}}

            {:error, _} ->
              {:ok, %{is_valid: false, invalid_reason: "FACILITATOR_ERROR"}}
          end

        _ ->
          {:ok, %{is_valid: false, invalid_reason: "FACILITATOR_ERROR"}}
      end
    end
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp payment_required_object(%__MODULE__{} = pw) do
    payload = %{
      "scheme" => "exact",
      "network" => pw.network,
      "amount" => pw.amount_base_units,
      "asset" => pw.asset,
      "payTo" => pw.wallet_address,
      "maxTimeoutSeconds" => pw.max_timeout_seconds
    }

    payload = if pw.resource, do: Map.put(payload, "resource", pw.resource), else: payload
    payload = if pw.description, do: Map.put(payload, "description", pw.description), else: payload
    if pw.mime_type, do: Map.put(payload, "mimeType", pw.mime_type), else: payload
  end
end

if Code.ensure_loaded?(Plug) do
  defmodule RemitMd.X402Paywall.Plug do
    @moduledoc """
    Plug middleware for x402 payment gating.

    Requires `plug` as a dependency in your project.

    ## Usage

        plug RemitMd.X402Paywall.Plug, paywall: paywall

    If the request lacks a valid `PAYMENT-SIGNATURE` header, returns 402
    with the `PAYMENT-REQUIRED` header. Otherwise, the request proceeds.
    """

    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      paywall = Keyword.fetch!(opts, :paywall)
      payment_sig = get_payment_sig(conn)

      case RemitMd.X402Paywall.check(paywall, payment_sig) do
        {:ok, %{is_valid: true}} ->
          conn

        {:ok, result} ->
          header_val = RemitMd.X402Paywall.payment_required_header(paywall)

          conn
          |> Plug.Conn.put_resp_header("payment-required", header_val)
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(402, Jason.encode!(%{
            error: "Payment required",
            invalidReason: result[:invalid_reason]
          }))
          |> Plug.Conn.halt()
      end
    end

    defp get_payment_sig(conn) do
      case Plug.Conn.get_req_header(conn, "payment-signature") do
        [sig | _] -> sig
        _ -> nil
      end
    end
  end
end
