#!/usr/bin/env elixir
# Remit SDK Acceptance -- Elixir: 9 flows against Base Sepolia.
#
# Flows: Direct, Escrow, Tab (2 charges), Stream, Bounty, Deposit, x402 Weather,
# AP2 Discovery, AP2 Payment.
#
# Usage:
#   cd sdk/acceptance/elixir
#   mix deps.get
#   ACCEPTANCE_API_URL=https://testnet.remit.md mix run test_flows.exs

Application.ensure_all_started(:inets)
Application.ensure_all_started(:ssl)
Application.ensure_all_started(:crypto)

# ── Config ────────────────────────────────────────────────────────────────────

api_url = System.get_env("ACCEPTANCE_API_URL", "https://testnet.remit.md")
rpc_url = System.get_env("ACCEPTANCE_RPC_URL", "https://sepolia.base.org")
chain_id = String.to_integer(System.get_env("CHAIN_ID", "84532"))
usdc_address = "0x2d846325766921935f37d5b4478196d3ef93707c"

_ = chain_id  # suppress unused warning; used in display

# ── Colors ────────────────────────────────────────────────────────────────────

green  = "\e[0;32m"
red    = "\e[0;31m"
cyan   = "\e[0;36m"
bold   = "\e[1m"
reset  = "\e[0m"

# ── Results agent ─────────────────────────────────────────────────────────────

{:ok, results_pid} = Agent.start_link(fn -> %{} end)

log_pass = fn flow, msg ->
  extra = if msg != "", do: " -- #{msg}", else: ""
  IO.puts("#{green}[PASS]#{reset} #{flow}#{extra}")
  Agent.update(results_pid, &Map.put(&1, flow, "PASS"))
end

log_fail = fn flow, msg ->
  IO.puts("#{red}[FAIL]#{reset} #{flow} -- #{msg}")
  Agent.update(results_pid, &Map.put(&1, flow, "FAIL"))
end

log_info = fn msg ->
  IO.puts("#{cyan}[INFO]#{reset} #{msg}")
end

log_tx = fn flow, step, tx_hash ->
  IO.puts("  [TX] #{flow} | #{step} | https://sepolia.basescan.org/tx/#{tx_hash}")
end

# ── Helpers ───────────────────────────────────────────────────────────────────

api_base = if String.ends_with?(api_url, "/api/v1"), do: api_url, else: "#{api_url}/api/v1"

get_usdc_balance = fn address ->
  hex = address |> String.downcase() |> String.trim_leading("0x") |> String.pad_leading(64, "0")
  data = "0x70a08231#{hex}"

  body = Jason.encode!(%{
    jsonrpc: "2.0", id: 1, method: "eth_call",
    params: [%{to: usdc_address, data: data}, "latest"]
  })

  {:ok, {{_, 200, _}, _, resp_body}} =
    :httpc.request(
      :post,
      {String.to_charlist(rpc_url), [{~c"content-type", ~c"application/json"}],
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

wait_for_balance_change = fn address, before ->
  deadline = System.monotonic_time(:second) + 30

  Stream.iterate(0, &(&1 + 1))
  |> Enum.reduce_while(before, fn _, _acc ->
    current = get_usdc_balance.(address)
    if abs(current - before) > 0.0001 do
      {:halt, current}
    else
      if System.monotonic_time(:second) < deadline do
        Process.sleep(2_000)
        {:cont, current}
      else
        {:halt, current}
      end
    end
  end)
end

fetch_contracts = fn ->
  url = ~c"#{api_base}/contracts"
  {:ok, {{_, 200, _}, _, body}} =
    :httpc.request(:get, {url, []}, [{:timeout, 10_000}], [])
  Jason.decode!(to_string(body))
end

contracts = fetch_contracts.()

create_wallet = fn ->
  key_hex = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  wallet = RemitMd.Wallet.new(
    private_key: "0x#{key_hex}",
    chain: "base_sepolia",
    api_url: api_base,
    router_address: contracts["router"]
  )

  %{wallet: wallet, key_hex: key_hex}
end

fund_wallet = fn tw, amount ->
  {:ok, _} = RemitMd.Wallet.mint(tw.wallet, to_string(amount))
  wait_for_balance_change.(tw.wallet.address, 0)
end

# ── Setup ─────────────────────────────────────────────────────────────────────

IO.puts("")
IO.puts("#{bold}Elixir SDK -- 9 Flow Acceptance Suite#{reset}")
IO.puts("  API: #{api_url}")
IO.puts("  RPC: #{rpc_url}")
IO.puts("")

log_info.("Creating agent wallet...")
agent = create_wallet.()
log_info.("  Agent:    #{agent.wallet.address}")

log_info.("Creating provider wallet...")
provider = create_wallet.()
log_info.("  Provider: #{provider.wallet.address}")

log_info.("Minting $100 USDC to agent...")
fund_wallet.(agent, 100)
agent_bal = get_usdc_balance.(agent.wallet.address)
log_info.("  Agent balance: $#{:erlang.float_to_binary(agent_bal, decimals: 2)}")

log_info.("Minting $100 USDC to provider...")
fund_wallet.(provider, 100)
provider_bal = get_usdc_balance.(provider.wallet.address)
log_info.("  Provider balance: $#{:erlang.float_to_binary(provider_bal, decimals: 2)}")
IO.puts("")

# ── Flow 1: Direct Payment ───────────────────────────────────────────────────

flow1 = fn ->
  flow = "1. Direct Payment"

  try do
    permit = RemitMd.Wallet.sign_permit(agent.wallet, contracts["router"], "2.0")

    {:ok, tx} = RemitMd.Wallet.pay(agent.wallet, provider.wallet.address, "1.000000",
      description: "elixir-acceptance-direct", permit: permit)

    if tx.tx_hash, do: log_tx.(flow, "pay", tx.tx_hash)
    log_pass.(flow, "tx=#{String.slice(tx.tx_hash || "", 0, 18)}...")
  rescue
    e ->
      log_fail.(flow, "#{inspect(e.__struct__)}: #{Exception.message(e)}")
      IO.puts(Exception.format(:error, e, __STACKTRACE__))
  end
end

# ── Flow 2: Escrow ────────────────────────────────────────────────────────────

flow2 = fn ->
  flow = "2. Escrow"

  try do
    permit = RemitMd.Wallet.sign_permit(agent.wallet, contracts["escrow"], "6.0")

    {:ok, escrow} = RemitMd.Wallet.create_escrow(agent.wallet, provider.wallet.address, "5.000000",
      permit: permit)

    escrow_id = escrow.escrow_id || escrow.invoice_id
    if escrow.tx_hash, do: log_tx.(flow, "fund", escrow.tx_hash)

    wait_for_balance_change.(agent.wallet.address, get_usdc_balance.(agent.wallet.address))
    Process.sleep(3_000)

    {:ok, claim} = RemitMd.Wallet.claim_start(provider.wallet, escrow_id)
    if claim.tx_hash, do: log_tx.(flow, "claimStart", claim.tx_hash)
    Process.sleep(3_000)

    {:ok, release} = RemitMd.Wallet.release_escrow(agent.wallet, escrow_id)
    if release.tx_hash, do: log_tx.(flow, "release", release.tx_hash)

    log_pass.(flow, "escrow_id=#{escrow_id}")
  rescue
    e ->
      log_fail.(flow, "#{inspect(e.__struct__)}: #{Exception.message(e)}")
      IO.puts(Exception.format(:error, e, __STACKTRACE__))
  end
end

# ── Flow 3: Metered Tab ──────────────────────────────────────────────────────

flow3 = fn ->
  flow = "3. Metered Tab"

  try do
    tab_contract = contracts["tab"]
    permit = RemitMd.Wallet.sign_permit(agent.wallet, tab_contract, "11.0")

    {:ok, tab} = RemitMd.Wallet.create_tab(agent.wallet, provider.wallet.address,
      "10.000000", "0.100000", permit: permit)

    tab_id = tab.tab_id || tab.id

    wait_for_balance_change.(agent.wallet.address, get_usdc_balance.(agent.wallet.address))

    # Charge 1: $2 (cumulative $2, call_count 1)
    sig1 = RemitMd.Wallet.sign_tab_charge(provider.wallet,
      tab_contract, tab_id, 2_000_000, 1)
    {:ok, charge1} = RemitMd.Wallet.charge_tab(provider.wallet, tab_id, 2.0, 2.0, 1, sig1)
    log_tx.(flow, "charge1", Map.get(charge1, :tx_hash) || "n/a")

    # Charge 2: $1 more (cumulative $3, call_count 2)
    sig2 = RemitMd.Wallet.sign_tab_charge(provider.wallet,
      tab_contract, tab_id, 3_000_000, 2)
    {:ok, charge2} = RemitMd.Wallet.charge_tab(provider.wallet, tab_id, 1.0, 3.0, 2, sig2)
    log_tx.(flow, "charge2", Map.get(charge2, :tx_hash) || "n/a")

    # Close with final state ($3, 2 calls)
    close_sig = RemitMd.Wallet.sign_tab_charge(provider.wallet,
      tab_contract, tab_id, 3_000_000, 2)
    {:ok, closed} = RemitMd.Wallet.close_tab(agent.wallet, tab_id,
      final_amount: 3.0, provider_sig: close_sig)

    log_tx.(flow, "close", Map.get(closed, :tx_hash) || "n/a")
    log_pass.(flow, "tab_id=#{tab_id}, charged=$3, 2 charges")
  rescue
    e ->
      log_fail.(flow, "#{inspect(e.__struct__)}: #{Exception.message(e)}")
      IO.puts(Exception.format(:error, e, __STACKTRACE__))
  end
end

# ── Flow 4: Stream ────────────────────────────────────────────────────────────

flow4 = fn ->
  flow = "4. Stream"

  try do
    permit = RemitMd.Wallet.sign_permit(agent.wallet, contracts["stream"], "6.0")

    {:ok, stream} = RemitMd.Wallet.create_stream(agent.wallet, provider.wallet.address,
      "0.01", "5.0", permit: permit)

    stream_id = stream.stream_id || stream.id
    if stream.started_at || stream.id, do: log_tx.(flow, "open", Map.get(stream, :tx_hash) || stream_id)

    wait_for_balance_change.(agent.wallet.address, get_usdc_balance.(agent.wallet.address))

    Process.sleep(5_000)

    {:ok, closed} = RemitMd.Wallet.close_stream(agent.wallet, stream_id)
    if Map.get(closed, :tx_hash), do: log_tx.(flow, "close", closed.tx_hash)

    log_pass.(flow, "stream_id=#{stream_id}")
  rescue
    e ->
      log_fail.(flow, "#{inspect(e.__struct__)}: #{Exception.message(e)}")
      IO.puts(Exception.format(:error, e, __STACKTRACE__))
  end
end

# ── Flow 5: Bounty ────────────────────────────────────────────────────────────

flow5 = fn ->
  flow = "5. Bounty"

  try do
    permit = RemitMd.Wallet.sign_permit(agent.wallet, contracts["bounty"], "6.0")

    bounty_deadline = :os.system_time(:second) + 3600
    {:ok, bounty} = RemitMd.Wallet.create_bounty(agent.wallet, "5.000000",
      "elixir acceptance bounty test", bounty_deadline, permit: permit)

    bounty_id = bounty.bounty_id || bounty.id
    if bounty.id, do: log_tx.(flow, "post", Map.get(bounty, :tx_hash) || bounty_id)

    wait_for_balance_change.(agent.wallet.address, get_usdc_balance.(agent.wallet.address))

    evidence_hash = "0x" <> String.duplicate("ab", 32)
    {:ok, submission} = RemitMd.Wallet.submit_bounty(provider.wallet, bounty_id, evidence_hash)

    submission_id = submission.id
    Process.sleep(5_000)

    {:ok, awarded} = RemitMd.Wallet.award_bounty(agent.wallet, bounty_id, submission_id)
    if Map.get(awarded, :tx_hash), do: log_tx.(flow, "award", awarded.tx_hash || "n/a")

    log_pass.(flow, "bounty_id=#{bounty_id}")
  rescue
    e ->
      log_fail.(flow, "#{inspect(e.__struct__)}: #{Exception.message(e)}")
      IO.puts(Exception.format(:error, e, __STACKTRACE__))
  end
end

# ── Flow 6: Deposit ───────────────────────────────────────────────────────────

flow6 = fn ->
  flow = "6. Deposit"

  try do
    permit = RemitMd.Wallet.sign_permit(agent.wallet, contracts["deposit"], "6.0")

    {:ok, deposit} = RemitMd.Wallet.place_deposit(agent.wallet, provider.wallet.address, "5.000000",
      expires_in: 3600, permit: permit)

    deposit_id = deposit.deposit_id || deposit.id
    if deposit.tx_hash, do: log_tx.(flow, "place", deposit.tx_hash)

    wait_for_balance_change.(agent.wallet.address, get_usdc_balance.(agent.wallet.address))

    {:ok, returned} = RemitMd.Wallet.return_deposit(provider.wallet, deposit_id)
    if returned.tx_hash, do: log_tx.(flow, "return", returned.tx_hash)

    log_pass.(flow, "deposit_id=#{deposit_id}")
  rescue
    e ->
      log_fail.(flow, "#{inspect(e.__struct__)}: #{Exception.message(e)}")
      IO.puts(Exception.format(:error, e, __STACKTRACE__))
  end
end

# ── Flow 7: x402 Weather ─────────────────────────────────────────────────────

flow7 = fn ->
  flow = "7. x402 Weather"

  try do
    # Step 1: Hit the paywall
    demo_url = ~c"#{api_base}/x402/demo"
    {:ok, {{_, status, _}, resp_headers, _resp_body}} =
      :httpc.request(:get, {demo_url, []}, [{:timeout, 10_000}], [])

    unless status == 402 do
      raise "Expected 402, got #{status}"
    end

    # Parse X-Payment-* headers (case-insensitive)
    find_header = fn headers, target ->
      target_lower = String.downcase(target)
      Enum.find_value(headers, fn {name, value} ->
        if String.downcase(to_string(name)) == target_lower do
          to_string(value)
        end
      end)
    end

    scheme = find_header.(resp_headers, "x-payment-scheme") || "exact"
    network = find_header.(resp_headers, "x-payment-network") || "eip155:84532"
    amount_str = find_header.(resp_headers, "x-payment-amount") || "5000000"
    asset = find_header.(resp_headers, "x-payment-asset") || usdc_address
    pay_to = find_header.(resp_headers, "x-payment-payto") || ""
    amount_raw = String.to_integer(amount_str)

    log_info.("  Paywall: #{scheme} | $#{:erlang.float_to_binary(amount_raw / 1_000_000, decimals: 2)} USDC | network=#{network}")

    # Step 2: Sign EIP-3009 TransferWithAuthorization
    parsed_chain_id = network |> String.split(":") |> List.last() |> String.to_integer()
    now = :os.system_time(:second)
    valid_before = now + 300
    nonce_bytes = :crypto.strong_rand_bytes(32)
    nonce_hex = "0x" <> Base.encode16(nonce_bytes, case: :lower)

    keccak = &RemitMd.Keccak.hash/1

    domain_type_hash =
      keccak.("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    name_hash = keccak.("USD Coin")
    version_hash = keccak.("2")

    pad_addr = fn addr ->
      hex = String.trim_leading(addr, "0x")
      addr_bytes = Base.decode16!(hex, case: :mixed)
      :binary.copy(<<0>>, 12) <> addr_bytes
    end

    domain_sep = keccak.(
      domain_type_hash <> name_hash <> version_hash <>
      <<parsed_chain_id::unsigned-big-integer-size(256)>> <> pad_addr.(asset)
    )

    transfer_type_hash =
      keccak.("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")

    struct_hash = keccak.(
      transfer_type_hash <>
      pad_addr.(agent.wallet.address) <>
      pad_addr.(pay_to) <>
      <<amount_raw::unsigned-big-integer-size(256)>> <>
      <<0::unsigned-big-integer-size(256)>> <>
      <<valid_before::unsigned-big-integer-size(256)>> <>
      nonce_bytes
    )

    digest = keccak.(<<0x19, 0x01>> <> domain_sep <> struct_hash)

    signer = RemitMd.PrivateKeySigner.new("0x#{agent.key_hex}")
    signature = RemitMd.PrivateKeySigner.sign(signer, digest)

    # Step 3: Settle on-chain via POST /x402/settle
    settle_body = Jason.encode!(%{
      paymentPayload: %{
        scheme: scheme,
        network: network,
        x402Version: 1,
        payload: %{
          signature: signature,
          authorization: %{
            from: agent.wallet.address,
            to: pay_to,
            value: amount_str,
            validAfter: "0",
            validBefore: to_string(valid_before),
            nonce: nonce_hex
          }
        }
      },
      paymentRequired: %{
        scheme: scheme,
        network: network,
        amount: amount_str,
        asset: asset,
        payTo: pay_to,
        maxTimeoutSeconds: 300
      }
    })

    # Build EIP-712 auth headers for settle endpoint
    auth_router = contracts["router"]
    auth_timestamp = :os.system_time(:second)
    auth_nonce_bytes = :crypto.strong_rand_bytes(32)
    auth_nonce_hex = "0x" <> Base.encode16(auth_nonce_bytes, case: :lower)

    # Domain separator: remit.md / 0.1
    auth_domain_type_hash =
      keccak.("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    auth_name_hash = keccak.("remit.md")
    auth_version_hash = keccak.("0.1")

    auth_domain_sep = keccak.(
      auth_domain_type_hash <> auth_name_hash <> auth_version_hash <>
      <<parsed_chain_id::unsigned-big-integer-size(256)>> <> pad_addr.(auth_router)
    )

    # APIRequest struct — string fields are keccak256-hashed in EIP-712
    auth_struct_type_hash =
      keccak.("APIRequest(string method,string path,uint256 timestamp,bytes32 nonce)")
    method_hash = keccak.("POST")
    path_hash_auth = keccak.("/api/v1/x402/settle")
    auth_struct_hash = keccak.(
      auth_struct_type_hash <> method_hash <> path_hash_auth <>
      <<auth_timestamp::unsigned-big-integer-size(256)>> <> auth_nonce_bytes
    )

    auth_digest = keccak.(<<0x19, 0x01>> <> auth_domain_sep <> auth_struct_hash)
    auth_signature = RemitMd.PrivateKeySigner.sign(signer, auth_digest)

    settle_url = String.to_charlist("#{api_base}/x402/settle")
    {:ok, {{_, settle_status, _}, _, settle_resp_body}} =
      :httpc.request(
        :post,
        {settle_url,
         [{~c"content-type", ~c"application/json"},
          {~c"x-remit-signature", String.to_charlist(auth_signature)},
          {~c"x-remit-agent", String.to_charlist(agent.wallet.address)},
          {~c"x-remit-timestamp", String.to_charlist(to_string(auth_timestamp))},
          {~c"x-remit-nonce", String.to_charlist(auth_nonce_hex)}],
         ~c"application/json",
         String.to_charlist(settle_body)},
        [{:timeout, 30_000}],
        []
      )

    unless settle_status in 200..299 do
      raise "Settle returned #{settle_status}: #{to_string(settle_resp_body)}"
    end

    settle_data = Jason.decode!(to_string(settle_resp_body))
    tx_hash = settle_data["transactionHash"] || ""

    unless tx_hash != "" do
      raise "Settle returned no transactionHash: #{inspect(settle_data)}"
    end
    log_tx.(flow, "settle", tx_hash)

    # Step 4: Fetch weather data with payment proof
    weather_url = String.to_charlist("#{api_base}/x402/demo")
    {:ok, {{_, weather_status, _}, _, weather_body}} =
      :httpc.request(
        :get,
        {weather_url, [{~c"x-payment-response", String.to_charlist(tx_hash)}]},
        [{:timeout, 10_000}],
        []
      )

    unless weather_status == 200 do
      raise "Weather fetch returned #{weather_status}"
    end

    weather = Jason.decode!(to_string(weather_body))

    # Display weather report
    loc = weather["location"] || %{}
    cur = weather["current"] || %{}
    cond_data = cur["condition"] || %{}

    city = loc["name"] || "Unknown"
    region = "#{loc["region"] || ""}, #{loc["country"] || ""}" |> String.trim(", ")
    temp_f = cur["temp_f"] || "?"
    temp_c = cur["temp_c"] || "?"
    condition = cond_data["text"] || cur["condition"] || "Unknown"
    humidity = cur["humidity"] || "?"
    wind_mph = cur["wind_mph"] || cur["wind_kph"] || "?"
    wind_dir = cur["wind_dir"] || ""

    IO.puts("")
    IO.puts("#{cyan}+---------------------------------------------+#{reset}")
    IO.puts("#{cyan}|#{reset}  #{bold}x402 Weather Report#{reset} (paid $#{:erlang.float_to_binary(amount_raw / 1_000_000, decimals: 2)} USDC)   #{cyan}|#{reset}")
    IO.puts("#{cyan}+---------------------------------------------+#{reset}")
    IO.puts("#{cyan}|#{reset}  City:        #{String.pad_trailing(to_string(city), 29)}#{cyan}|#{reset}")
    IO.puts("#{cyan}|#{reset}  Region:      #{String.pad_trailing(to_string(region), 29)}#{cyan}|#{reset}")
    IO.puts("#{cyan}|#{reset}  Temperature: #{temp_f}F / #{temp_c}C#{String.duplicate(" ", max(0, 21 - String.length(to_string(temp_f)) - String.length(to_string(temp_c))))}#{cyan}|#{reset}")
    IO.puts("#{cyan}|#{reset}  Condition:   #{String.pad_trailing(to_string(condition), 29)}#{cyan}|#{reset}")
    IO.puts("#{cyan}|#{reset}  Humidity:    #{humidity}%#{String.duplicate(" ", max(0, 28 - String.length(to_string(humidity))))}#{cyan}|#{reset}")
    IO.puts("#{cyan}|#{reset}  Wind:        #{wind_mph} mph #{wind_dir}#{String.duplicate(" ", max(0, 22 - String.length(to_string(wind_mph)) - String.length(to_string(wind_dir))))}#{cyan}|#{reset}")
    IO.puts("#{cyan}+---------------------------------------------+#{reset}")
    IO.puts("")

    log_pass.(flow, "city=#{city}, tx=#{String.slice(tx_hash, 0, 18)}...")
  rescue
    e ->
      log_fail.(flow, "#{inspect(e.__struct__)}: #{Exception.message(e)}")
      IO.puts(Exception.format(:error, e, __STACKTRACE__))
  end
end

# ── Flow 8: AP2 Discovery ────────────────────────────────────────────────────

flow8 = fn ->
  flow = "8. AP2 Discovery"

  try do
    {:ok, card} = RemitMd.A2A.discover(api_url)

    IO.puts("")
    IO.puts("#{cyan}+---------------------------------------------+#{reset}")
    IO.puts("#{cyan}|#{reset}  #{bold}A2A Agent Card#{reset}                            #{cyan}|#{reset}")
    IO.puts("#{cyan}+---------------------------------------------+#{reset}")
    IO.puts("#{cyan}|#{reset}  Name:     #{String.pad_trailing(to_string(card.name), 32)}#{cyan}|#{reset}")
    IO.puts("#{cyan}|#{reset}  Version:  #{String.pad_trailing(to_string(card.version), 32)}#{cyan}|#{reset}")
    IO.puts("#{cyan}|#{reset}  Protocol: #{String.pad_trailing(to_string(card.protocol_version), 32)}#{cyan}|#{reset}")
    IO.puts("#{cyan}|#{reset}  URL:      #{String.pad_trailing(String.slice(to_string(card.url), 0, 32), 32)}#{cyan}|#{reset}")

    if card.skills != [] do
      IO.puts("#{cyan}|#{reset}  Skills:   #{String.pad_trailing("#{length(card.skills)} total", 32)}#{cyan}|#{reset}")
      card.skills
      |> Enum.take(5)
      |> Enum.each(fn s ->
        name = String.slice(s.name, 0, 38)
        IO.puts("#{cyan}|#{reset}    - #{String.pad_trailing(name, 38)}#{cyan}|#{reset}")
      end)
    end

    if card.x402 != %{} do
      x402_info = "settle=#{card.x402["settleEndpoint"] || "n/a"}" |> String.slice(0, 38)
      IO.puts("#{cyan}|#{reset}  x402:     #{String.pad_trailing(x402_info, 32)}#{cyan}|#{reset}")
    end

    caps = card.capabilities
    exts = if caps.extensions != [] do
      caps.extensions |> Enum.map(fn e -> e.uri |> String.split("/") |> List.last() end) |> Enum.join(", ")
    else
      "none"
    end
    IO.puts("#{cyan}|#{reset}  Caps:     streaming=#{caps.streaming}, exts=#{String.slice(exts, 0, 16)}   #{cyan}|#{reset}")
    IO.puts("#{cyan}+---------------------------------------------+#{reset}")
    IO.puts("")

    log_pass.(flow, "name=#{card.name}")
  rescue
    e ->
      log_fail.(flow, "#{inspect(e.__struct__)}: #{Exception.message(e)}")
      IO.puts(Exception.format(:error, e, __STACKTRACE__))
  end
end

# ── Flow 9: AP2 Payment ──────────────────────────────────────────────────────

flow9 = fn ->
  flow = "9. AP2 Payment"

  try do
    {:ok, card} = RemitMd.A2A.discover(api_url)

    permit = RemitMd.Wallet.sign_permit(agent.wallet, contracts["router"], "2.0")

    mandate = RemitMd.A2A.IntentMandate.new(
      mandate_id: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower),
      expires_at: "2099-12-31T23:59:59Z",
      issuer: agent.wallet.address,
      max_amount: "5.00",
      currency: "USDC"
    )

    signer = RemitMd.PrivateKeySigner.new("0x#{agent.key_hex}")
    client = RemitMd.A2A.Client.from_card(card, signer,
      chain: "base_sepolia", verifying_contract: contracts["router"])

    {:ok, task} = RemitMd.A2A.Client.send(client,
      to: provider.wallet.address,
      amount: 1.0,
      memo: "elixir-acceptance-ap2",
      mandate: mandate,
      permit: permit
    )

    tx_hash = RemitMd.A2A.Task.get_tx_hash(task)
    if tx_hash, do: log_tx.(flow, "a2a-pay", tx_hash)

    # Verify persistence
    {:ok, fetched} = RemitMd.A2A.Client.get_task(client, task.id)

    unless fetched.id == task.id do
      raise "Fetched task id mismatch: #{fetched.id} != #{task.id}"
    end

    log_pass.(flow, "task_id=#{task.id}, state=#{task.status.state}")
  rescue
    e ->
      log_fail.(flow, "#{inspect(e.__struct__)}: #{Exception.message(e)}")
      IO.puts(Exception.format(:error, e, __STACKTRACE__))
  end
end

# ── Run all flows ─────────────────────────────────────────────────────────────

flows = [
  {"1. Direct Payment", flow1},
  {"2. Escrow", flow2},
  {"3. Metered Tab", flow3},
  {"4. Stream", flow4},
  {"5. Bounty", flow5},
  {"6. Deposit", flow6},
  {"7. x402 Weather", flow7},
  {"8. AP2 Discovery", flow8},
  {"9. AP2 Payment", flow9}
]

for {_name, flow_fn} <- flows do
  flow_fn.()
  # Allow indexer to catch up with on-chain nonce between permit-consuming flows
  :timer.sleep(5000)
end

# ── Summary ───────────────────────────────────────────────────────────────────

results = Agent.get(results_pid, & &1)
passed = results |> Map.values() |> Enum.count(&(&1 == "PASS"))
failed = results |> Map.values() |> Enum.count(&(&1 == "FAIL"))
skipped = 9 - passed - failed

IO.puts("")
IO.puts("#{bold}Elixir Summary: #{green}#{passed} passed#{reset}, #{red}#{failed} failed#{reset} / 9 flows")
IO.puts(Jason.encode!(%{passed: passed, failed: failed, skipped: skipped}))

Agent.stop(results_pid)

if failed > 0 do
  System.halt(1)
else
  System.halt(0)
end
