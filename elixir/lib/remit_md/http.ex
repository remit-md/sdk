defmodule RemitMd.Http do
  @moduledoc false
  # HTTP transport layer. Signs each request with EIP-712-style headers and
  # retries transient failures with exponential backoff.
  # Uses Erlang's built-in :httpc (via :inets) — no external HTTP deps.

  alias RemitMd.Error

  @chain_config %{
    "base"         => %{url: "https://api.remit.md/v0",         chain_id: 8453},
    "base_sepolia" => %{url: "https://testnet-api.remit.md/v0", chain_id: 84532},
    "arbitrum"     => %{url: "https://api.remit.md/v0",         chain_id: 42161},
    "optimism"     => %{url: "https://api.remit.md/v0",         chain_id: 10}
  }

  @max_retries 3
  @base_delay_ms 500
  @retry_codes [429, 500, 502, 503, 504]

  @enforce_keys [:base_url, :signer, :chain_id]
  defstruct [:base_url, :signer, :chain_id]

  def new(opts) do
    chain = Keyword.get(opts, :chain, "base")

    cfg =
      Map.get(@chain_config, chain) ||
        raise Error.new(Error.chain_unsupported(), "Unknown chain: #{chain}")

    base_url = Keyword.get(opts, :api_url, cfg.url)
    signer = Keyword.fetch!(opts, :signer)

    %__MODULE__{
      base_url: base_url,
      signer: signer,
      chain_id: cfg.chain_id
    }
  end

  def get(%__MODULE__{} = t, path) do
    request(t, :get, path, nil, 1)
  end

  def post(%__MODULE__{} = t, path, body) do
    request(t, :post, path, body, 1)
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp request(transport, method, path, body, attempt) do
    url = transport.base_url <> path
    nonce = generate_nonce()
    timestamp = Integer.to_string(:os.system_time(:second))
    body_json = if body, do: Jason.encode!(body), else: ""

    signed_payload =
      [method_string(method), path, nonce, timestamp, body_json]
      |> Enum.join("\n")

    signature = call_sign(transport.signer, signed_payload)
    agent_address = call_address(transport.signer)

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"x-remit-signature", String.to_charlist(signature)},
      {~c"x-remit-agent", String.to_charlist(agent_address)},
      {~c"x-remit-timestamp", String.to_charlist(timestamp)},
      {~c"x-remit-nonce", String.to_charlist(nonce)},
      {~c"x-remit-chain-id", String.to_charlist(Integer.to_string(transport.chain_id))}
    ]

    url_charlist = String.to_charlist(url)

    result =
      case method do
        :get ->
          :httpc.request(:get, {url_charlist, headers}, http_opts(), [])

        :post ->
          body_charlist = String.to_charlist(body_json)
          :httpc.request(:post, {url_charlist, headers, ~c"application/json", body_charlist}, http_opts(), [])
      end

    case result do
      {:ok, {{_version, status, _reason}, _resp_headers, resp_body}} ->
        handle_response(status, to_string(resp_body), url, transport, method, path, body, attempt)

      {:error, reason} ->
        if attempt < @max_retries do
          Process.sleep(@base_delay_ms * trunc(:math.pow(2, attempt - 1)))
          request(transport, method, path, body, attempt + 1)
        else
          raise Error.new(Error.network_error(), "Network error: #{inspect(reason)}")
        end
    end
  end

  defp handle_response(status, resp_body, _url, transport, method, path, req_body, attempt) do
    parsed = if resp_body == "", do: %{}, else: Jason.decode!(resp_body)

    cond do
      status in 200..299 ->
        parsed

      status in @retry_codes and attempt < @max_retries ->
        Process.sleep(@base_delay_ms * trunc(:math.pow(2, attempt - 1)))
        request(transport, method, path, req_body, attempt + 1)

      status == 400 ->
        code = Map.get(parsed, "code", Error.server_error())
        raise Error.new(code, Map.get(parsed, "message", "Bad request"), context: parsed)

      status == 401 ->
        raise Error.new(Error.unauthorized(), "Authentication failed — check private key and chain ID")

      status == 403 ->
        raise Error.new(Error.forbidden(), Map.get(parsed, "message", "Forbidden"))

      status == 404 ->
        raise Error.new(Error.not_found(), Map.get(parsed, "message", "Resource not found"))

      status == 429 ->
        raise Error.new(Error.rate_limited(), "Rate limit exceeded — back off and retry")

      status in 500..599 ->
        raise Error.new(Error.server_error(), "Server error #{status}")

      true ->
        raise Error.new(Error.server_error(), "Unexpected status #{status}")
    end
  end

  defp generate_nonce do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp method_string(:get), do: "GET"
  defp method_string(:post), do: "POST"

  defp http_opts do
    [timeout: 10_000, connect_timeout: 5_000]
  end

  # Dispatch to behaviour implementations (structs or modules)
  defp call_sign(%{__struct__: mod} = signer, message) do
    mod.sign(signer, message)
  end

  defp call_address(%{__struct__: mod} = signer) do
    mod.address(signer)
  end
end
