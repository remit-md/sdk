# Elixir SDK acceptance tests: all 9 payment flows on live Base Sepolia.
#
# Run: mix test test/acceptance_test.exs --include acceptance
#
# Env vars (all optional):
#   ACCEPTANCE_API_URL  - default: https://testnet.remit.md
#   ACCEPTANCE_RPC_URL  - default: https://sepolia.base.org

defmodule RemitMd.AcceptanceTest do
  use ExUnit.Case, async: false

  alias RemitMd.{A2A, Http, Wallet}
  alias RemitMd.Models.PermitSignature

  @moduletag :acceptance

  @api_url System.get_env("ACCEPTANCE_API_URL", "https://testnet.remit.md")
  @rpc_url System.get_env("ACCEPTANCE_RPC_URL", "https://sepolia.base.org")

  # ─── Helpers ────────────────────────────────────────────────────────────

  defp fetch_contracts do
    :inets.start()
    :ssl.start()
    url = ~c"#{@api_url}/api/v1/contracts"

    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:get, {url, []}, [{:timeout, 10_000}], [])

    Jason.decode!(to_string(body))
  end

  defp create_test_wallet(contracts) do
    key_hex = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    base_url = if String.ends_with?(@api_url, "/api/v1"), do: @api_url, else: "#{@api_url}/api/v1"

    wallet = Wallet.new(
      private_key: "0x#{key_hex}",
      chain: "base_sepolia",
      api_url: base_url,
      router_address: contracts["router"]
    )

    IO.puts("[ACCEPTANCE] wallet: #{wallet.address} (chain=84532)")
    wallet
  end

  defp get_usdc_balance(address, usdc_address) do
    :inets.start()
    :ssl.start()
    hex = address |> String.downcase() |> String.trim_leading("0x") |> String.pad_leading(64, "0")
    data = "0x70a08231#{hex}"

    body = Jason.encode!(%{
      jsonrpc: "2.0", id: 1, method: "eth_call",
      params: [%{to: usdc_address, data: data}, "latest"]
    })

    {:ok, {{_, 200, _}, _, resp_body}} =
      :httpc.request(
        :post,
        {String.to_charlist(@rpc_url), [{~c"content-type", ~c"application/json"}],
         ~c"application/json", String.to_charlist(body)},
        [{:timeout, 10_000}],
        []
      )

    result = Jason.decode!(to_string(resp_body))
    raw = result["result"] |> String.trim_leading("0x")
    raw = if raw == "", do: "0", else: raw
    {val, _} = Integer.parse(raw, 16)
    val / 1_000_000.0
  end

  defp wait_for_balance_change(address, before, usdc_address, timeout_secs \\ 30) do
    deadline = System.monotonic_time(:second) + timeout_secs
    do_wait_balance(address, before, usdc_address, deadline)
  end

  defp do_wait_balance(address, before, usdc_address, deadline) do
    current = get_usdc_balance(address, usdc_address)
    if abs(current - before) > 0.0001 do
      current
    else
      if System.monotonic_time(:second) < deadline do
        Process.sleep(2_000)
        do_wait_balance(address, before, usdc_address, deadline)
      else
        current
      end
    end
  end

  defp log_tx(flow, step, tx_hash) do
    IO.puts("[ACCEPTANCE] #{flow} | #{step} | tx=#{tx_hash} | https://sepolia.basescan.org/tx/#{tx_hash}")
  end

  defp assert_balance_change(label, before, after_val, expected) do
    actual = after_val - before
    tolerance = max(abs(expected) * 0.001, 0.02)
    assert abs(actual - expected) <= tolerance,
      "#{label}: expected delta #{expected}, got #{actual} (before=#{before}, after=#{after_val})"
  end

  defp fund_wallet(wallet, amount, usdc_address) do
    IO.puts("[ACCEPTANCE] mint: #{amount} USDC -> #{wallet.address}")
    {:ok, mint_resp} = Wallet.mint(wallet, to_string(amount))
    log_tx("mint", "mint", mint_resp.tx_hash)
    wait_for_balance_change(wallet.address, 0, usdc_address)
  end

  # ─── setup_all: shared wallets ──────────────────────────────────────────

  setup_all do
    contracts = fetch_contracts()
    usdc_address = contracts["usdc"]

    agent = create_test_wallet(contracts)
    provider = create_test_wallet(contracts)
    fund_wallet(agent, 100, usdc_address)

    %{agent: agent, provider: provider, contracts: contracts, usdc: usdc_address}
  end

  # ─── Flow 1: Direct Payment ────────────────────────────────────────────

  @tag :acceptance
  test "01_direct", %{agent: agent, provider: provider, usdc: usdc} do
    amount = 1.0

    agent_before = get_usdc_balance(agent.address, usdc)
    provider_before = get_usdc_balance(provider.address, usdc)

    permit = Wallet.sign_permit(agent, "direct", 2.0)

    {:ok, tx} = Wallet.pay(agent, provider.address, "1.000000",
      description: "acceptance-direct", permit: permit)
    assert String.starts_with?(tx.tx_hash, "0x")
    log_tx("direct", "pay", tx.tx_hash)

    agent_after = wait_for_balance_change(agent.address, agent_before, usdc)
    provider_after = get_usdc_balance(provider.address, usdc)

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change("provider", provider_before, provider_after, amount * 0.99)
    IO.puts("[ACCEPTANCE] direct | PASS")
  end

  # ─── Flow 2: Escrow ────────────────────────────────────────────────────

  @tag :acceptance
  test "02_escrow", %{agent: agent, provider: provider, usdc: usdc} do
    amount = 2.0

    agent_before = get_usdc_balance(agent.address, usdc)
    provider_before = get_usdc_balance(provider.address, usdc)

    permit = Wallet.sign_permit(agent, "escrow", 3.0)

    {:ok, escrow} = Wallet.create_escrow(agent, provider.address, "2.000000", permit: permit)
    assert escrow.invoice_id != nil || escrow.escrow_id != nil
    escrow_id = escrow.invoice_id || escrow.escrow_id
    if escrow.tx_hash, do: log_tx("escrow", "create", escrow.tx_hash)

    wait_for_balance_change(agent.address, agent_before, usdc)

    {:ok, claim_tx} = Wallet.claim_start(provider, escrow_id)
    log_tx("escrow", "claim_start", claim_tx.tx_hash)
    Process.sleep(5_000)

    {:ok, release_tx} = Wallet.release_escrow(agent, escrow_id)
    log_tx("escrow", "release", release_tx.tx_hash)

    provider_after = wait_for_balance_change(provider.address, provider_before, usdc)
    agent_after = get_usdc_balance(agent.address, usdc)

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change("provider", provider_before, provider_after, amount * 0.99)
    IO.puts("[ACCEPTANCE] escrow | PASS")
  end

  # ─── Flow 3: Tab ───────────────────────────────────────────────────────

  @tag :acceptance
  test "03_tab", %{agent: agent, provider: provider, contracts: contracts, usdc: usdc} do
    limit = 5.0
    charge_amount = 1.0
    charge_units = trunc(charge_amount * 1_000_000)

    agent_before = get_usdc_balance(agent.address, usdc)
    provider_before = get_usdc_balance(provider.address, usdc)

    permit = Wallet.sign_permit(agent, "tab", limit + 1.0)

    {:ok, tab} = Wallet.create_tab(agent, provider.address, "5.000000", "0.100000",
      permit: permit)
    tab_id = tab.id || tab.tab_id
    assert tab_id != nil
    IO.puts("[ACCEPTANCE] tab | create | tab_id=#{tab_id}")

    wait_for_balance_change(agent.address, agent_before, usdc)

    tab_contract = contracts["tab"]
    call_count = 1

    charge_sig = Wallet.sign_tab_charge(provider, tab_contract, tab_id, charge_units, call_count)

    {:ok, charge} = Wallet.charge_tab(provider, tab_id, charge_amount, charge_amount, call_count, charge_sig)
    assert (charge.tab_id || tab_id) != nil
    IO.puts("[ACCEPTANCE] tab | charge | tab_id=#{tab_id}")

    close_sig = Wallet.sign_tab_charge(provider, tab_contract, tab_id, charge_units, call_count)

    {:ok, closed} = Wallet.close_tab(agent, tab_id,
      final_amount: charge_amount, provider_sig: close_sig)
    if closed.tx_hash, do: log_tx("tab", "close", closed.tx_hash)

    provider_after = wait_for_balance_change(provider.address, provider_before, usdc)
    agent_after = get_usdc_balance(agent.address, usdc)

    assert_balance_change("agent", agent_before, agent_after, -charge_amount)
    assert_balance_change("provider", provider_before, provider_after, charge_amount * 0.99)
    IO.puts("[ACCEPTANCE] tab | PASS")
  end

  # ─── Flow 4: Stream ────────────────────────────────────────────────────

  @tag :acceptance
  test "04_stream", %{agent: agent, provider: provider, usdc: usdc} do
    rate = "0.10"
    max_total = "2.00"

    agent_before = get_usdc_balance(agent.address, usdc)
    provider_before = get_usdc_balance(provider.address, usdc)

    permit = Wallet.sign_permit(agent, "stream", 3.0)

    {:ok, stream} = Wallet.create_stream(agent, provider.address, rate, max_total,
      permit: permit)
    stream_id = stream.id || stream.stream_id
    assert stream_id != nil
    IO.puts("[ACCEPTANCE] stream | create | stream_id=#{stream_id}")

    wait_for_balance_change(agent.address, agent_before, usdc)
    Process.sleep(5_000)

    {:ok, closed} = Wallet.close_stream(agent, stream_id)
    assert closed.tx_hash
    log_tx("stream", "close", closed.tx_hash)

    provider_after = wait_for_balance_change(provider.address, provider_before, usdc)
    agent_after = get_usdc_balance(agent.address, usdc)

    agent_loss = agent_before - agent_after
    assert agent_loss > 0.05, "agent should lose money, loss=#{agent_loss}"
    assert agent_loss <= 2.01

    provider_gain = provider_after - provider_before
    assert provider_gain > 0.04, "provider should gain, gain=#{provider_gain}"
    IO.puts("[ACCEPTANCE] stream | PASS")
  end

  # ─── Flow 5: Bounty ────────────────────────────────────────────────────

  @tag :acceptance
  test "05_bounty", %{agent: agent, provider: provider, usdc: usdc} do
    amount = 2.0
    deadline_ts = :os.system_time(:second) + 3600

    agent_before = get_usdc_balance(agent.address, usdc)
    provider_before = get_usdc_balance(provider.address, usdc)

    permit = Wallet.sign_permit(agent, "bounty", 3.0)

    {:ok, bounty} = Wallet.create_bounty(agent, "2.000000",
      "acceptance-bounty", deadline_ts, permit: permit)
    bounty_id = bounty.id || bounty.bounty_id
    assert bounty_id != nil
    IO.puts("[ACCEPTANCE] bounty | create | bounty_id=#{bounty_id}")

    wait_for_balance_change(agent.address, agent_before, usdc)

    evidence = "0x" <> String.duplicate("ab", 32)
    {:ok, sub} = Wallet.submit_bounty(provider, bounty_id, evidence)
    IO.puts("[ACCEPTANCE] bounty | submit | id=#{bounty_id}")

    # Retry award up to 15 times (Ponder indexer lag)
    awarded = Enum.reduce_while(0..14, nil, fn attempt, _acc ->
      Process.sleep(3_000)
      case Wallet.award_bounty(agent, bounty_id, 1) do
        {:ok, result} ->
          {:halt, result}
        {:error, e} ->
          if attempt < 14 do
            IO.puts("[ACCEPTANCE] bounty award retry #{attempt + 1}: #{inspect(e)}")
            {:cont, nil}
          else
            raise "bounty award failed after 15 retries: #{inspect(e)}"
          end
      end
    end)

    assert awarded != nil
    assert awarded.status == "awarded"
    IO.puts("[ACCEPTANCE] bounty | award | bounty_id=#{bounty_id}")

    provider_after = wait_for_balance_change(provider.address, provider_before, usdc)
    agent_after = get_usdc_balance(agent.address, usdc)

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change("provider", provider_before, provider_after, amount * 0.99)
    IO.puts("[ACCEPTANCE] bounty | PASS")
  end

  # ─── Flow 6: Deposit ───────────────────────────────────────────────────

  @tag :acceptance
  test "06_deposit", %{agent: agent, provider: provider, usdc: usdc} do
    amount = 2.0

    agent_before = get_usdc_balance(agent.address, usdc)

    permit = Wallet.sign_permit(agent, "deposit", 3.0)

    {:ok, deposit} = Wallet.place_deposit(agent, provider.address, "2.000000",
      expires_in: 3600, permit: permit)
    deposit_id = deposit.id || deposit.deposit_id
    assert deposit_id != nil
    if deposit.tx_hash, do: log_tx("deposit", "place", deposit.tx_hash)

    agent_mid = wait_for_balance_change(agent.address, agent_before, usdc)
    assert_balance_change("agent locked", agent_before, agent_mid, -amount)

    {:ok, returned} = Wallet.return_deposit(provider, deposit_id)
    assert returned.status == "returned" || returned.tx_hash != nil
    if returned.tx_hash, do: log_tx("deposit", "return", returned.tx_hash)

    agent_after = wait_for_balance_change(agent.address, agent_mid, usdc)
    assert_balance_change("agent refund", agent_before, agent_after, 0)
    IO.puts("[ACCEPTANCE] deposit | PASS")
  end

  # ─── Flow 7: x402 Prepare ──────────────────────────────────────────────

  @tag :acceptance
  test "07_x402_prepare", %{agent: agent, contracts: contracts} do
    {:ok, contract_addrs} = Wallet.get_contracts(agent)

    payment_required = %{
      "scheme" => "exact",
      "network" => "eip155:84532",
      "amount" => "100000",
      "asset" => contract_addrs.usdc,
      "payTo" => contract_addrs.router,
      "maxTimeoutSeconds" => 60
    }
    encoded = Base.encode64(Jason.encode!(payment_required))

    # Use Http.post directly to call /x402/prepare
    data = Http.post(agent.transport, "/x402/prepare", %{
      "payment_required" => encoded,
      "payer" => agent.address
    })

    assert is_map(data), "x402/prepare should return a map"
    assert Map.has_key?(data, "hash"), "x402/prepare missing hash: #{inspect(data)}"
    assert String.starts_with?(data["hash"], "0x")
    assert String.length(data["hash"]) == 66
    assert Map.has_key?(data, "from")
    assert Map.has_key?(data, "to")
    assert Map.has_key?(data, "value")

    IO.puts(
      "[ACCEPTANCE] x402 | prepare | hash=#{String.slice(data["hash"], 0, 18)}..." <>
      " | from=#{String.slice(data["from"], 0, 10)}..."
    )
    IO.puts("[ACCEPTANCE] x402_prepare | PASS")
  end

  # ─── Flow 8: AP2 Discovery ─────────────────────────────────────────────

  @tag :acceptance
  test "08_ap2_discovery", _context do
    {:ok, card} = A2A.discover(@api_url)

    assert card.name != nil and card.name != "", "agent card should have a name"
    assert card.url != nil and card.url != "", "agent card should have a URL"
    assert length(card.skills) > 0, "agent card should have skills"
    assert card.x402 != nil and card.x402 != %{}, "agent card should have x402 config"

    IO.puts(
      "[ACCEPTANCE] ap2-discovery | name=#{card.name}" <>
      " | skills=#{length(card.skills)}" <>
      " | x402=#{card.x402 != %{}}"
    )
    IO.puts("[ACCEPTANCE] ap2_discovery | PASS")
  end

  # ─── Flow 9: AP2 Payment ───────────────────────────────────────────────

  @tag :acceptance
  test "09_ap2_payment", %{agent: agent, provider: provider, contracts: contracts, usdc: usdc} do
    amount = 1.0

    agent_before = get_usdc_balance(agent.address, usdc)
    provider_before = get_usdc_balance(provider.address, usdc)

    {:ok, card} = A2A.discover(@api_url)

    permit = Wallet.sign_permit(agent, "direct", 2.0)

    client = A2A.Client.from_card(card, agent.signer,
      chain: "base_sepolia",
      verifying_contract: contracts["router"]
    )

    {:ok, task} = A2A.Client.send(client,
      to: provider.address,
      amount: amount,
      memo: "acceptance-ap2",
      permit: permit
    )

    assert task.status.state == "completed",
      "A2A task failed: state=#{task.status.state}, message=#{task.status.message}"

    tx_hash = RemitMd.A2A.Task.get_tx_hash(task)
    assert tx_hash != nil and String.starts_with?(tx_hash, "0x"),
      "A2A task should return a tx hash"
    log_tx("ap2-payment", "#{amount} USDC via A2A", tx_hash)

    agent_after = wait_for_balance_change(agent.address, agent_before, usdc)
    provider_after = get_usdc_balance(provider.address, usdc)

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change("provider", provider_before, provider_after, amount * 0.99)
    IO.puts("[ACCEPTANCE] ap2_payment | PASS")
  end
end
