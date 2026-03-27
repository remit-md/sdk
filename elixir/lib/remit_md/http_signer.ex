defmodule RemitMd.HttpSigner do
  @moduledoc """
  Signer backed by a local HTTP signing server.

  Delegates EIP-712 signing to an HTTP server on localhost (typically
  `http://127.0.0.1:7402`). The signer server holds the encrypted key;
  this adapter only needs a bearer token and URL.

  - Bearer token is stored privately, never exposed via `inspect/1` or `to_string/1`.
  - Address is cached at construction time (`GET /address`).
  - `sign/2` POSTs the raw 32-byte digest to `POST /sign/digest`.
  - All errors are explicit - no silent fallbacks.

  ## Usage

      signer = RemitMd.HttpSigner.new("http://127.0.0.1:7402", "rmit_sk_...")
      wallet = RemitMd.Wallet.new(signer: signer, chain: "base")
  """

  @behaviour RemitMd.Signer

  alias RemitMd.Error

  @enforce_keys [:address, :__url__, :__token__]
  defstruct [:address, :__url__, :__token__]

  @doc """
  Create an HttpSigner by fetching and caching the wallet address from
  `GET /address` on the signer server.

  Raises `RemitMd.Error` on network errors, auth failures, or missing address.
  """
  def new(url, token) when is_binary(url) and is_binary(token) do
    url = String.trim_trailing(url, "/")

    # Ensure :inets and :ssl are started (Application.start handles this,
    # but tests or scripts may not boot the OTP app).
    ensure_http_deps()

    address = fetch_address(url, token)

    %__MODULE__{address: address, __url__: url, __token__: token}
  end

  @impl true
  def sign(%__MODULE__{__url__: url, __token__: token}, digest)
      when is_binary(digest) and byte_size(digest) == 32 do
    ensure_http_deps()

    digest_hex = "0x" <> Base.encode16(digest, case: :lower)
    body = Jason.encode!(%{digest: digest_hex})

    request_url = String.to_charlist(url <> "/sign/digest")
    headers = auth_headers(token)

    result =
      :httpc.request(
        :post,
        {request_url, headers, ~c"application/json", String.to_charlist(body)},
        http_opts(),
        []
      )

    case result do
      {:ok, {{_, 200, _}, _, resp_body}} ->
        parse_signature_response(to_string(resp_body))

      {:ok, {{_, 401, _}, _, _}} ->
        raise Error.new(
          Error.unauthorized(),
          "HttpSigner: unauthorized -- check your REMIT_SIGNER_TOKEN"
        )

      {:ok, {{_, 403, _}, _, resp_body}} ->
        reason = extract_reason(to_string(resp_body))

        raise Error.new(
          Error.forbidden(),
          "HttpSigner: policy denied -- #{reason}"
        )

      {:ok, {{_, status, _}, _, resp_body}} ->
        reason = extract_reason(to_string(resp_body))

        raise Error.new(
          Error.server_error(),
          "HttpSigner: POST /sign/digest failed (#{status}): #{reason}"
        )

      {:error, reason} ->
        raise Error.new(
          Error.network_error(),
          "HttpSigner: cannot reach signer server: #{inspect(reason)}"
        )
    end
  end

  @impl true
  def address(%__MODULE__{address: addr}), do: addr

  # ─── Protocol implementations (never leak token) ────────────────────────────

  defimpl Inspect do
    def inspect(%RemitMd.HttpSigner{address: addr}, _opts) do
      "#RemitMd.HttpSigner<address=#{addr}>"
    end
  end

  defimpl String.Chars do
    def to_string(%RemitMd.HttpSigner{address: addr}) do
      "#RemitMd.HttpSigner<address=#{addr}>"
    end
  end

  # ─── Private ────────────────────────────────────────────────────────────────

  defp fetch_address(url, token) do
    request_url = String.to_charlist(url <> "/address")
    headers = auth_headers(token)

    result = :httpc.request(:get, {request_url, headers}, http_opts(), [])

    case result do
      {:ok, {{_, 200, _}, _, resp_body}} ->
        parse_address_response(to_string(resp_body))

      {:ok, {{_, 401, _}, _, _}} ->
        raise Error.new(
          Error.unauthorized(),
          "HttpSigner: unauthorized -- check your REMIT_SIGNER_TOKEN"
        )

      {:ok, {{_, 403, _}, _, resp_body}} ->
        reason = extract_reason(to_string(resp_body))

        raise Error.new(
          Error.forbidden(),
          "HttpSigner: policy denied -- #{reason}"
        )

      {:ok, {{_, status, _}, _, resp_body}} ->
        reason = extract_reason(to_string(resp_body))

        raise Error.new(
          Error.server_error(),
          "HttpSigner: GET /address failed (#{status}): #{reason}"
        )

      {:error, reason} ->
        raise Error.new(
          Error.network_error(),
          "HttpSigner: cannot reach signer server at #{url}: #{inspect(reason)}"
        )
    end
  end

  defp parse_address_response(body) do
    case Jason.decode(body) do
      {:ok, %{"address" => address}} when is_binary(address) and address != "" ->
        address

      {:ok, _} ->
        raise Error.new(
          Error.server_error(),
          "HttpSigner: GET /address returned no address"
        )

      {:error, _} ->
        raise Error.new(
          Error.server_error(),
          "HttpSigner: GET /address returned invalid JSON"
        )
    end
  end

  defp parse_signature_response(body) do
    case Jason.decode(body) do
      {:ok, %{"signature" => sig}} when is_binary(sig) and sig != "" ->
        sig

      {:ok, _} ->
        raise Error.new(
          Error.server_error(),
          "HttpSigner: server returned no signature"
        )

      {:error, _} ->
        raise Error.new(
          Error.server_error(),
          "HttpSigner: POST /sign/digest returned invalid JSON"
        )
    end
  end

  defp extract_reason(body) do
    case Jason.decode(body) do
      {:ok, %{"reason" => reason}} when is_binary(reason) and reason != "" ->
        reason

      {:ok, %{"error" => error}} when is_binary(error) and error != "" ->
        error

      _ ->
        if body != "" and String.length(body) < 200, do: body, else: "unknown"
    end
  end

  defp auth_headers(token) do
    [{~c"authorization", String.to_charlist("Bearer #{token}")}]
  end

  defp http_opts do
    [timeout: 10_000, connect_timeout: 5_000]
  end

  defp ensure_http_deps do
    case :inets.start() do
      :ok -> :ok
      {:error, {:already_started, :inets}} -> :ok
    end

    case :ssl.start() do
      :ok -> :ok
      {:error, {:already_started, :ssl}} -> :ok
    end
  end
end
