defmodule RemitMd.A2A do
  @moduledoc """
  A2A / AP2 - agent card discovery and A2A JSON-RPC task client.

  ## Example

      {:ok, card} = RemitMd.A2A.discover("https://remit.md")
      IO.puts(card.name)     # => "remit.md"
      IO.puts(card.url)      # => "https://remit.md/a2a"

  Spec: https://google.github.io/A2A/specification/
  AP2:  https://ap2-protocol.org/
  """

  @type extension :: %{
    uri: String.t(),
    description: String.t(),
    required: boolean()
  }

  @type capabilities :: %{
    streaming: boolean(),
    push_notifications: boolean(),
    state_transition_history: boolean(),
    extensions: [extension()]
  }

  @type skill :: %{
    id: String.t(),
    name: String.t(),
    description: String.t(),
    tags: [String.t()]
  }

  @type agent_card :: %{
    protocol_version: String.t(),
    name: String.t(),
    description: String.t(),
    url: String.t(),
    version: String.t(),
    documentation_url: String.t(),
    capabilities: capabilities(),
    skills: [skill()],
    x402: map()
  }

  @doc """
  Fetch and parse the A2A agent card from `base_url/.well-known/agent-card.json`.

  Returns `{:ok, agent_card}` on success or `{:error, reason}` on failure.
  """
  @spec discover(String.t()) :: {:ok, agent_card()} | {:error, term()}
  def discover(base_url) do
    url = String.trim_trailing(base_url, "/") <> "/.well-known/agent-card.json"
    uri = String.to_charlist(url)

    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {uri, [{~c"accept", ~c"application/json"}]}, [], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        json = IO.iodata_to_binary(body)

        case Jason.decode(json) do
          {:ok, data} -> {:ok, parse_card(data)}
          {:error, reason} -> {:error, {:parse_error, reason}}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  # ─── Private ─────────────────────────────────────────────────────────────────

  defp parse_card(data) do
    caps = data["capabilities"] || %{}
    extensions =
      (caps["extensions"] || [])
      |> Enum.map(fn e ->
        %{
          uri: e["uri"] || "",
          description: e["description"] || "",
          required: e["required"] || false
        }
      end)

    capabilities = %{
      streaming: caps["streaming"] || false,
      push_notifications: caps["pushNotifications"] || false,
      state_transition_history: caps["stateTransitionHistory"] || false,
      extensions: extensions
    }

    skills =
      (data["skills"] || [])
      |> Enum.map(fn s ->
        %{
          id: s["id"] || "",
          name: s["name"] || "",
          description: s["description"] || "",
          tags: s["tags"] || []
        }
      end)

    %{
      protocol_version: data["protocolVersion"] || "0.6",
      name: data["name"] || "",
      description: data["description"] || "",
      url: data["url"] || "",
      version: data["version"] || "",
      documentation_url: data["documentationUrl"] || "",
      capabilities: capabilities,
      skills: skills,
      x402: data["x402"] || %{}
    }
  end
end

# ─── A2A Task types ────────────────────────────────────────────────────────────

defmodule RemitMd.A2A.TaskStatus do
  @moduledoc "Status of an A2A task."
  defstruct [:state, :message]

  @type t :: %__MODULE__{
    state: String.t(),
    message: String.t() | nil
  }

  @doc false
  def from_map(nil), do: %__MODULE__{state: "unknown", message: nil}
  def from_map(m) when is_map(m) do
    msg = case Map.get(m, "message") do
      %{"text" => text} -> text
      text when is_binary(text) -> text
      _ -> nil
    end
    %__MODULE__{
      state: Map.get(m, "state", "unknown"),
      message: msg
    }
  end
end

defmodule RemitMd.A2A.ArtifactPart do
  @moduledoc "A part of an A2A artifact."
  defstruct [:kind, :data]

  @type t :: %__MODULE__{
    kind: String.t(),
    data: map() | nil
  }

  @doc false
  def from_map(m) do
    %__MODULE__{
      kind: Map.get(m, "kind", ""),
      data: Map.get(m, "data")
    }
  end
end

defmodule RemitMd.A2A.Artifact do
  @moduledoc "An A2A task artifact."
  defstruct [:name, :parts]

  @type t :: %__MODULE__{
    name: String.t() | nil,
    parts: [RemitMd.A2A.ArtifactPart.t()]
  }

  @doc false
  def from_map(m) do
    parts = (Map.get(m, "parts") || []) |> Enum.map(&RemitMd.A2A.ArtifactPart.from_map/1)
    %__MODULE__{
      name: Map.get(m, "name"),
      parts: parts
    }
  end
end

defmodule RemitMd.A2A.Task do
  @moduledoc "An A2A task."
  defstruct [:id, :status, :artifacts]

  @type t :: %__MODULE__{
    id: String.t(),
    status: RemitMd.A2A.TaskStatus.t(),
    artifacts: [RemitMd.A2A.Artifact.t()]
  }

  @doc false
  def from_map(m) do
    artifacts = (Map.get(m, "artifacts") || []) |> Enum.map(&RemitMd.A2A.Artifact.from_map/1)
    %__MODULE__{
      id: Map.get(m, "id", ""),
      status: RemitMd.A2A.TaskStatus.from_map(Map.get(m, "status")),
      artifacts: artifacts
    }
  end

  @doc "Extract txHash from task artifacts, if present."
  @spec get_tx_hash(t()) :: String.t() | nil
  def get_tx_hash(%__MODULE__{artifacts: artifacts}) do
    Enum.find_value(artifacts, fn artifact ->
      Enum.find_value(artifact.parts, fn part ->
        case part.data do
          %{"txHash" => tx} when is_binary(tx) -> tx
          _ -> nil
        end
      end)
    end)
  end
end

# ─── IntentMandate ──────────────────────────────────────────────────────────────

defmodule RemitMd.A2A.IntentMandate do
  @moduledoc "An intent mandate for A2A payments."
  defstruct [:mandate_id, :expires_at, :issuer, :allowance]

  @type t :: %__MODULE__{
    mandate_id: String.t(),
    expires_at: String.t(),
    issuer: String.t(),
    allowance: %{max_amount: String.t(), currency: String.t()}
  }

  @doc "Create a new IntentMandate."
  def new(opts) do
    %__MODULE__{
      mandate_id: Keyword.fetch!(opts, :mandate_id),
      expires_at: Keyword.fetch!(opts, :expires_at),
      issuer: Keyword.fetch!(opts, :issuer),
      allowance: %{
        max_amount: Keyword.fetch!(opts, :max_amount),
        currency: Keyword.get(opts, :currency, "USDC")
      }
    }
  end

  @doc false
  def to_map(%__MODULE__{} = m) do
    %{
      "mandateId" => m.mandate_id,
      "expiresAt" => m.expires_at,
      "issuer" => m.issuer,
      "allowance" => %{
        "maxAmount" => m.allowance.max_amount,
        "currency" => m.allowance.currency
      }
    }
  end
end

# ─── A2A Client ─────────────────────────────────────────────────────────────────

defmodule RemitMd.A2A.Client do
  @moduledoc """
  A2A JSON-RPC client - send payments and manage tasks via the A2A protocol.

  ## Example

      {:ok, card} = RemitMd.A2A.discover("https://remit.md")
      signer = RemitMd.PrivateKeySigner.new("0x...")
      client = RemitMd.A2A.Client.from_card(card, signer)
      {:ok, task} = RemitMd.A2A.Client.send(client, to: "0xRecipient", amount: 10.0)
      IO.puts(task.status.state)
  """

  alias RemitMd.Http

  @chain_ids %{
    "base" => 8453,
    "base-sepolia" => 84532,
    "base_sepolia" => 84532
  }

  @enforce_keys [:http, :path]
  defstruct [:http, :path]

  @type t :: %__MODULE__{
    http: Http.t(),
    path: String.t()
  }

  @doc """
  Create a client from an A2AClientOptions-style keyword list.

  ## Options

  - `:endpoint` - full A2A endpoint URL (required)
  - `:signer` - signer struct (required)
  - `:chain_id` - numeric chain ID (required)
  - `:verifying_contract` - router contract address (default: `""`)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    signer = Keyword.fetch!(opts, :signer)
    chain_id = Keyword.fetch!(opts, :chain_id)
    verifying_contract = Keyword.get(opts, :verifying_contract, "")

    parsed = URI.parse(endpoint)
    base_url = "#{parsed.scheme}://#{parsed.authority}"
    path = parsed.path || "/a2a"

    # Build Http transport manually
    chain = Enum.find_value(@chain_ids, "base", fn {k, v} -> if v == chain_id, do: k end)

    http = Http.new(
      signer: signer,
      chain: chain,
      api_url: base_url,
      router_address: verifying_contract
    )

    %__MODULE__{http: http, path: path}
  end

  @doc """
  Convenience constructor from an agent card and a signer.

  ## Options

  - `:chain` - chain name (default: `"base"`)
  - `:verifying_contract` - router contract address (default: `""`)
  """
  @spec from_card(map(), term(), keyword()) :: t()
  def from_card(card, signer, opts \\ []) do
    chain = Keyword.get(opts, :chain, "base")
    chain_id = Map.get(@chain_ids, chain, 8453)

    new(
      endpoint: card.url || card[:url],
      signer: signer,
      chain_id: chain_id,
      verifying_contract: Keyword.get(opts, :verifying_contract, "")
    )
  end

  @doc """
  Send a direct USDC payment via `message/send`.

  ## Options

  - `:to` - recipient address (required)
  - `:amount` - USDC amount (required)
  - `:memo` - payment memo (default: `""`)
  - `:mandate` - `%RemitMd.A2A.IntentMandate{}` (optional)
  - `:permit` - `%RemitMd.Models.PermitSignature{}` for gasless approval (optional)

  Returns `{:ok, %RemitMd.A2A.Task{}}` or `{:error, reason}`.
  """
  @spec send(t(), keyword()) :: {:ok, RemitMd.A2A.Task.t()} | {:error, term()}
  def send(%__MODULE__{} = client, opts) do
    to = Keyword.fetch!(opts, :to)
    amount = Keyword.fetch!(opts, :amount)
    memo = Keyword.get(opts, :memo, "")
    mandate = Keyword.get(opts, :mandate)
    permit = Keyword.get(opts, :permit)

    nonce = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    message_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    amount_str = if is_float(amount), do: :erlang.float_to_binary(amount, decimals: 2), else: to_string(amount)

    data = %{
      "model" => "direct",
      "to" => to,
      "amount" => amount_str,
      "memo" => memo,
      "nonce" => nonce
    }

    data =
      if permit do
        Map.put(data, "permit", RemitMd.Models.PermitSignature.to_map(permit))
      else
        data
      end

    message = %{
      "messageId" => message_id,
      "role" => "user",
      "parts" => [
        %{
          "kind" => "data",
          "data" => data
        }
      ]
    }

    message =
      if mandate do
        Map.put(message, "metadata", %{"mandate" => RemitMd.A2A.IntentMandate.to_map(mandate)})
      else
        message
      end

    rpc(client, "message/send", %{"message" => message}, message_id)
  end

  @doc "Fetch the current state of an A2A task by ID."
  @spec get_task(t(), String.t()) :: {:ok, RemitMd.A2A.Task.t()} | {:error, term()}
  def get_task(%__MODULE__{} = client, task_id) do
    rpc(client, "tasks/get", %{"id" => task_id}, String.slice(task_id, 0, 16))
  end

  @doc "Cancel an in-progress A2A task."
  @spec cancel_task(t(), String.t()) :: {:ok, RemitMd.A2A.Task.t()} | {:error, term()}
  def cancel_task(%__MODULE__{} = client, task_id) do
    rpc(client, "tasks/cancel", %{"id" => task_id}, String.slice(task_id, 0, 16))
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp rpc(%__MODULE__{http: http, path: path}, method, params, call_id) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => call_id,
      "method" => method,
      "params" => params
    }

    try do
      data = Http.post(http, path, body)

      case data do
        %{"error" => %{"message" => msg}} ->
          {:error, "A2A error: #{msg}"}

        %{"error" => err} ->
          {:error, "A2A error: #{inspect(err)}"}

        %{"result" => result} ->
          {:ok, RemitMd.A2A.Task.from_map(result)}

        _ ->
          # Response may be the task directly (no result wrapper)
          {:ok, RemitMd.A2A.Task.from_map(data)}
      end
    rescue
      e in RemitMd.Error -> {:error, e}
    end
  end
end
