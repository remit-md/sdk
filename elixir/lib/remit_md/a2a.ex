defmodule RemitMd.A2A do
  @moduledoc """
  A2A / AP2 — agent card discovery.

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
