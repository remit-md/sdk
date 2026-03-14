defmodule RemitMd.Http do
  @moduledoc false
  # HTTP transport layer. Signs each request with EIP-712 headers and
  # retries transient failures with exponential backoff.
  # Uses Erlang's built-in :httpc (via :inets) — no external HTTP deps.

  alias RemitMd.Error

  @chain_config %{
    "base"         => %{url: "https://api.remit.md/api/v0",         chain_id: 8453},
    "base_sepolia" => %{url: "https://testnet-api.remit.md/api/v0", chain_id: 84532}
  }

  @max_retries 3
  @base_delay_ms 500
  @retry_codes [429, 500, 502, 503, 504]

  @enforce_keys [:base_url, :signer, :chain_id, :router_address]
  defstruct [:base_url, :signer, :chain_id, :router_address]

  def new(opts) do
    chain = Keyword.get(opts, :chain, "base")

    cfg =
      Map.get(@chain_config, chain) ||
        raise Error.new(Error.chain_unsupported(), "Unknown chain: #{chain}")

    base_url = Keyword.get(opts, :api_url, cfg.url)
    signer = Keyword.fetch!(opts, :signer)
    router_address = Keyword.get(opts, :router_address, "")

    %__MODULE__{
      base_url: base_url,
      signer: signer,
      chain_id: cfg.chain_id,
      router_address: router_address
    }
  end

  def get(%__MODULE__{} = t, path) do
    request(t, :get, path, nil, 1)
  end

  def post(%__MODULE__{} = t, path, body) do
    request(t, :post, path, body, 1)
  end

  # ─── EIP-712 hash (exposed for golden-vector testing) ──────────────────

  @doc false
  def eip712_hash(chain_id, router_address, method, path, timestamp, nonce_bytes)
      when is_binary(nonce_bytes) and byte_size(nonce_bytes) == 32 do
    keccak = &RemitMd.Keccak.hash/1

    domain_type_hash =
      keccak.("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")

    request_type_hash =
      keccak.("APIRequest(string method,string path,uint256 timestamp,bytes32 nonce)")

    # Domain separator
    name_hash = keccak.("remit.md")
    version_hash = keccak.("0.1")
    chain_id_enc = <<chain_id::unsigned-big-integer-size(256)>>
    contract_enc = address_to_bytes32(router_address)

    domain_separator =
      keccak.(domain_type_hash <> name_hash <> version_hash <> chain_id_enc <> contract_enc)

    # Struct hash
    method_hash = keccak.(method)
    path_hash = keccak.(path)
    timestamp_enc = <<timestamp::unsigned-big-integer-size(256)>>

    struct_hash =
      keccak.(request_type_hash <> method_hash <> path_hash <> timestamp_enc <> nonce_bytes)

    # Final: keccak256(0x1901 || domainSeparator || structHash)
    keccak.(<<0x19, 0x01>> <> domain_separator <> struct_hash)
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp request(transport, method, path, body, attempt) do
    url = transport.base_url <> path

    # 32-byte random nonce
    nonce_bytes = :crypto.strong_rand_bytes(32)
    nonce_hex = "0x" <> Base.encode16(nonce_bytes, case: :lower)

    # Unix epoch timestamp
    timestamp = :os.system_time(:second)

    body_json = if body, do: Jason.encode!(body), else: ""

    # EIP-712 must sign the full URL path (including /api/v0 base path).
    # Extract the path component from the full URL so the signature covers
    # the same string the server sees when it receives the request.
    full_path = URI.parse(url).path

    # EIP-712 hash and signature — sign the full path (including /api/v0 prefix).
    digest =
      eip712_hash(
        transport.chain_id,
        transport.router_address,
        method_string(method),
        full_path,
        timestamp,
        nonce_bytes
      )

    signature = call_sign(transport.signer, digest)
    agent_address = call_address(transport.signer)

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"x-remit-agent", String.to_charlist(agent_address)},
      {~c"x-remit-nonce", String.to_charlist(nonce_hex)},
      {~c"x-remit-timestamp", String.to_charlist(Integer.to_string(timestamp))},
      {~c"x-remit-signature", String.to_charlist(signature)}
    ]

    url_charlist = String.to_charlist(url)

    result =
      case method do
        :get ->
          :httpc.request(:get, {url_charlist, headers}, http_opts(), [])

        :post ->
          body_charlist = String.to_charlist(body_json)

          :httpc.request(
            :post,
            {url_charlist, headers, ~c"application/json", body_charlist},
            http_opts(),
            []
          )
      end

    case result do
      {:ok, {{_version, status, _reason}, _resp_headers, resp_body}} ->
        handle_response(
          status,
          to_string(resp_body),
          url,
          transport,
          method,
          path,
          body,
          attempt
        )

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
    parsed =
      if resp_body == "" do
        %{}
      else
        case Jason.decode(resp_body) do
          {:ok, data} -> data
          {:error, _} -> %{"message" => resp_body}
        end
      end

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
        raise Error.new(
          Error.unauthorized(),
          "Authentication failed — check private key and chain ID"
        )

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
