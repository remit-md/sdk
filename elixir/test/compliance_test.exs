defmodule RemitMd.ComplianceTest do
  # Compliance tests: Elixir SDK against a real running server.
  #
  # Tests are tagged @tag :compliance and skipped when the server is unreachable.
  # Boot the server with:
  #   docker compose -f docker-compose.compliance.yml up -d
  #
  # Environment variables:
  #   REMIT_TEST_SERVER_URL  (default: http://localhost:3000)
  #   REMIT_ROUTER_ADDRESS   (default: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8)
  use ExUnit.Case, async: false

  alias RemitMd.Wallet

  @server_url System.get_env("REMIT_TEST_SERVER_URL", "http://localhost:3000")
  @router_address System.get_env(
    "REMIT_ROUTER_ADDRESS",
    "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
  )

  # ─── Shared state ─────────────────────────────────────────────────────────

  # Agent holds the shared funded payer key (pk) so we only call mint once.
  defmodule SharedPayer do
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> nil end, name: __MODULE__)
    def get, do: Agent.get(__MODULE__, & &1)
    def set(val), do: Agent.update(__MODULE__, fn _ -> val end)
  end

  setup_all do
    {:ok, _} = SharedPayer.start_link([])
    :ok
  end

  # ─── Helpers ──────────────────────────────────────────────────────────────

  defp server_available? do
    :inets.start()
    :ssl.start()
    url = ~c"#{@server_url}/health"

    case :httpc.request(:get, {url, []}, [{:timeout, 3000}], []) do
      {:ok, {{_, 200, _}, _, _}} -> true
      _ -> false
    end
  end

  defp http_post(path, body, token \\ nil) do
    :inets.start()
    :ssl.start()
    url = ~c"#{@server_url}#{path}"
    json = Jason.encode!(body)
    headers = [
      {~c"content-type", ~c"application/json"}
      | if(token, do: [{~c"authorization", ~c"Bearer #{token}"}], else: [])
    ]

    {:ok, {{_, status, _}, _headers, resp_body}} =
      :httpc.request(
        :post,
        {url, headers, ~c"application/json", json},
        [{:timeout, 10_000}],
        []
      )

    {status, Jason.decode!(to_string(resp_body))}
  end

  defp http_get(path, token) do
    :inets.start()
    :ssl.start()
    url = ~c"#{@server_url}#{path}"
    headers = [{~c"authorization", ~c"Bearer #{token}"}]

    {:ok, {{_, status, _}, _headers, resp_body}} =
      :httpc.request(:get, {url, headers}, [{:timeout, 10_000}], [])

    {status, Jason.decode!(to_string(resp_body))}
  end

  defp register_and_get_key do
    ts = :os.system_time(:millisecond)
    email = "compliance.elixir.#{ts}@test.remitmd.local"

    {201, reg} =
      http_post("/api/v0/auth/register", %{email: email, password: "ComplianceTestPass1!"})

    token       = reg["token"] || raise "register failed: #{inspect(reg)}"
    wallet_addr = reg["wallet_address"] || raise "no wallet_address in register response"

    {200, key_data} = http_get("/api/v0/auth/agent-key", token)
    private_key = key_data["private_key"] || raise "agent-key failed: #{inspect(key_data)}"

    {private_key, wallet_addr}
  end

  defp fund_wallet(wallet_addr) do
    {200, resp} = http_post("/api/v0/mint", %{wallet: wallet_addr, amount: 1000})
    assert resp["tx_hash"] != nil, "mint response must contain tx_hash, got: #{inspect(resp)}"
  end

  defp make_wallet(private_key) do
    Wallet.new(
      private_key: private_key,
      chain: "base_sepolia",
      api_url: @server_url <> "/api/v0",
      router_address: @router_address
    )
  end

  defp get_shared_payer do
    case SharedPayer.get() do
      nil ->
        {pk, addr} = register_and_get_key()
        fund_wallet(addr)
        SharedPayer.set(pk)
        make_wallet(pk)

      pk ->
        make_wallet(pk)
    end
  end

  # ─── Auth tests ───────────────────────────────────────────────────────────

  test "authenticated request returns balance, not 401" do
    if not server_available?() do
      IO.puts("SKIP: compliance server not reachable at #{@server_url}")
      :ok
    else
      wallet = get_shared_payer()

      # reputation/2 makes an authenticated GET to /api/v0/reputation/{address} —
      # this endpoint exists for all registered addresses and returns 401 if auth fails.
      {:ok, rep} = Wallet.reputation(wallet, wallet.address)
      assert rep != nil
    end
  end

  test "unauthenticated POST /payments/direct returns 401" do
    if not server_available?() do
      :ok
    else
      {status, _body} =
        http_post("/api/v0/payments/direct", %{
          to: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
          amount: "1.000000"
        })

      assert status == 401, "unauthenticated POST must return 401, got: #{status}"
    end
  end

  # ─── Payment tests ────────────────────────────────────────────────────────

  test "pay_direct happy path returns tx_hash" do
    if not server_available?() do
      :ok
    else
      payer = get_shared_payer()
      {_pk, payee_addr} = register_and_get_key()

      {:ok, tx} = Wallet.pay(payer, payee_addr, "5.0", description: "elixir compliance test")
      assert tx.tx_hash != nil
      assert tx.tx_hash != ""
    end
  end

  test "pay_direct below minimum returns error" do
    if not server_available?() do
      :ok
    else
      payer = get_shared_payer()
      {_pk, payee_addr} = register_and_get_key()

      result = Wallet.pay(payer, payee_addr, "0.0001")
      assert match?({:error, _}, result),
             "pay with amount below minimum must return {:error, ...}, got: #{inspect(result)}"
    end
  end
end
