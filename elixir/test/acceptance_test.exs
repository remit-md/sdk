# Elixir SDK acceptance tests: all 7 payment flows on live Base Sepolia.
#
# Run: mix test test/acceptance_test.exs --include acceptance
#
# Env vars (all optional):
#   ACCEPTANCE_API_URL  — default: https://remit.md
#   ACCEPTANCE_RPC_URL  — default: https://sepolia.base.org

defmodule RemitMd.AcceptanceTest do
  use ExUnit.Case, async: false

  alias RemitMd.Wallet

  @moduletag :acceptance

  @api_url System.get_env("ACCEPTANCE_API_URL", "https://remit.md")
  @rpc_url System.get_env("ACCEPTANCE_RPC_URL", "https://sepolia.base.org")
  @usdc_address "0x2d846325766921935f37d5b4478196d3ef93707c"
  @fee_wallet "0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38"
  @chain_id 84532

  # ─── Helpers ──────────────────────────────────────────────────────────────

  defp fetch_contracts do
    :inets.start()
    :ssl.start()
    url = ~c"#{@api_url}/api/v1/contracts"

    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:get, {url, []}, [{:timeout, 10_000}], [])

    Jason.decode!(to_string(body))
  end

  defp create_test_wallet do
    key_hex = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    contracts = fetch_contracts()
    base_url = if String.ends_with?(@api_url, "/api/v1"), do: @api_url, else: "#{@api_url}/api/v1"

    wallet = Wallet.new(
      private_key: "0x#{key_hex}",
      chain: "base_sepolia",
      api_url: base_url,
      router_address: contracts["router"]
    )

    %{wallet: wallet, key_hex: key_hex}
  end

  defp get_usdc_balance(address) do
    :inets.start()
    :ssl.start()
    hex = address |> String.downcase() |> String.trim_leading("0x") |> String.pad_leading(64, "0")
    data = "0x70a08231#{hex}"

    body = Jason.encode!(%{
      jsonrpc: "2.0", id: 1, method: "eth_call",
      params: [%{to: @usdc_address, data: data}, "latest"]
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

  defp get_fee_balance, do: get_usdc_balance(@fee_wallet)

  defp wait_for_balance_change(address, before, timeout_secs \\ 30) do
    deadline = System.monotonic_time(:second) + timeout_secs
    do_wait_balance(address, before, deadline)
  end

  defp do_wait_balance(address, before, deadline) do
    current = get_usdc_balance(address)
    if abs(current - before) > 0.0001 do
      current
    else
      if System.monotonic_time(:second) < deadline do
        Process.sleep(2_000)
        do_wait_balance(address, before, deadline)
      else
        current
      end
    end
  end

  defp assert_balance_change(label, before, after_val, expected) do
    actual = after_val - before
    tolerance = max(abs(expected) * 0.001, 0.02)
    assert abs(actual - expected) <= tolerance,
      "#{label}: expected delta #{expected}, got #{actual} (before=#{before}, after=#{after_val})"
  end

  defp fund_wallet(tw, amount) do
    {:ok, _} = Wallet.mint(tw.wallet, to_string(amount))
    wait_for_balance_change(tw.wallet.address, 0)
  end

  # ─── EIP-2612 Permit Signing ───────────────────────────────────────────

  defp keccak256(data), do: RemitMd.Keccak.hash(data)

  defp pad_address(addr) do
    hex = String.trim_leading(addr, "0x")
    addr_bytes = Base.decode16!(hex, case: :mixed)
    :binary.copy(<<0>>, 12) <> addr_bytes
  end

  defp pad_uint256(value) do
    <<value::unsigned-big-integer-size(256)>>
  end

  defp sign_usdc_permit(key_hex, owner, spender, value, nonce, deadline) do
    # Domain separator
    domain_type_hash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    name_hash = keccak256("USD Coin")
    version_hash = keccak256("2")
    usdc_padded = pad_address(@usdc_address)

    domain_data = domain_type_hash <> name_hash <> version_hash <> pad_uint256(@chain_id) <> usdc_padded
    domain_sep = keccak256(domain_data)

    # Permit struct hash
    permit_type_hash = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
    struct_data = permit_type_hash <> pad_address(owner) <> pad_address(spender) <>
                  pad_uint256(value) <> pad_uint256(nonce) <> pad_uint256(deadline)
    struct_hash = keccak256(struct_data)

    # EIP-712 digest
    final_data = <<0x19, 0x01>> <> domain_sep <> struct_hash
    digest = keccak256(final_data)

    # Sign using the SDK's signer
    signer = RemitMd.PrivateKeySigner.new("0x#{key_hex}")
    sig_hex = RemitMd.PrivateKeySigner.sign(signer, digest)

    # Parse r, s, v from the 65-byte hex signature
    sig_bytes = sig_hex |> String.trim_leading("0x") |> Base.decode16!(case: :mixed)
    <<r_bytes::binary-size(32), s_bytes::binary-size(32), v>> = sig_bytes

    %RemitMd.Models.PermitSignature{
      value: value,
      deadline: deadline,
      v: v,
      r: "0x" <> Base.encode16(r_bytes, case: :lower),
      s: "0x" <> Base.encode16(s_bytes, case: :lower)
    }
  end

  # ─── Test: Direct Payment ──────────────────────────────────────────────

  @tag :acceptance
  test "direct payment with permit" do
    agent = create_test_wallet()
    provider = create_test_wallet()
    fund_wallet(agent, 100)

    amount = 1.0
    fee = 0.01
    provider_receives = amount - fee

    agent_before = get_usdc_balance(agent.wallet.address)
    provider_before = get_usdc_balance(provider.wallet.address)
    fee_before = get_fee_balance()

    # Sign EIP-2612 permit for Router
    contracts = fetch_contracts()
    deadline = :os.system_time(:second) + 3600
    permit = sign_usdc_permit(
      agent.key_hex, agent.wallet.address, contracts["router"],
      2_000_000, 0, deadline
    )

    {:ok, tx} = Wallet.pay(agent.wallet, provider.wallet.address, "1.000000",
      description: "elixir-sdk-acceptance", permit: permit)
    assert String.starts_with?(tx.tx_hash, "0x")

    agent_after = wait_for_balance_change(agent.wallet.address, agent_before)
    provider_after = get_usdc_balance(provider.wallet.address)
    fee_after = get_fee_balance()

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change("provider", provider_before, provider_after, provider_receives)
    assert_balance_change("fee wallet", fee_before, fee_after, fee)
  end

  # ─── Test: Escrow Lifecycle ────────────────────────────────────────────

  @tag :acceptance
  test "escrow lifecycle (create, claim-start, release)" do
    agent = create_test_wallet()
    provider = create_test_wallet()
    fund_wallet(agent, 100)

    amount = 5.0
    fee = amount * 0.01
    provider_receives = amount - fee

    agent_before = get_usdc_balance(agent.wallet.address)
    provider_before = get_usdc_balance(provider.wallet.address)
    fee_before = get_fee_balance()

    # Sign EIP-2612 permit for Escrow contract
    contracts = fetch_contracts()
    deadline = :os.system_time(:second) + 3600
    permit = sign_usdc_permit(
      agent.key_hex, agent.wallet.address, contracts["escrow"],
      6_000_000, 0, deadline
    )

    {:ok, escrow} = Wallet.create_escrow(agent.wallet, provider.wallet.address, "5.000000",
      permit: permit)
    assert escrow.escrow_id != nil

    # Wait for on-chain lock
    wait_for_balance_change(agent.wallet.address, agent_before)

    # Provider claims start
    {:ok, _} = Wallet.claim_start(provider.wallet, escrow.escrow_id)
    Process.sleep(5_000)

    # Agent releases
    {:ok, _} = Wallet.release_escrow(agent.wallet, escrow.escrow_id)

    # Verify balances
    provider_after = wait_for_balance_change(provider.wallet.address, provider_before)
    fee_after = get_fee_balance()
    agent_after = get_usdc_balance(agent.wallet.address)

    assert_balance_change("agent", agent_before, agent_after, -amount)
    assert_balance_change("provider", provider_before, provider_after, provider_receives)
    assert_balance_change("fee wallet", fee_before, fee_after, fee)
  end

  # ─── Test: Tab Lifecycle ───────────────────────────────────────────────

  @tag :acceptance
  test "tab lifecycle (create, charge, close)" do
    payer = create_test_wallet()
    provider = create_test_wallet()
    fund_wallet(payer, 100)

    contracts = fetch_contracts()

    # Sign permit for the Tab contract
    deadline = :os.system_time(:second) + 3600
    permit = sign_usdc_permit(
      payer.key_hex, payer.wallet.address, contracts["tab"],
      20_000_000, 0, deadline
    )

    payer_before = get_usdc_balance(payer.wallet.address)
    _fee_before = get_fee_balance()

    # 1. Create tab: $10 limit, $0.10 per call
    {:ok, tab} = Wallet.create_tab(payer.wallet, provider.wallet.address,
      "10.000000", "0.100000", permit: permit)
    assert tab.tab_id != nil

    # Wait for on-chain funding
    wait_for_balance_change(payer.wallet.address, payer_before)

    # 2. Charge tab: $0.10 charge, cumulative $0.10, callCount 1
    charge_sig = Wallet.sign_tab_charge(provider.wallet,
      contracts["tab"], tab.tab_id, 100_000, 1)
    {:ok, charge} = Wallet.charge_tab(provider.wallet, tab.tab_id, 0.10, 0.10, 1, charge_sig)
    assert charge.tab_id == tab.tab_id

    # 3. Close tab with final settlement
    close_sig = Wallet.sign_tab_charge(provider.wallet,
      contracts["tab"], tab.tab_id, 100_000, 1)
    {:ok, closed} = Wallet.close_tab(payer.wallet, tab.tab_id,
      final_amount: 0.10, provider_sig: close_sig)
    assert closed.status != "open"

    # 4. Verify: payer should have lost funds
    payer_after = wait_for_balance_change(payer.wallet.address, payer_before)
    payer_delta = payer_after - payer_before
    assert payer_delta < 0
  end

  # ─── Test: Stream Lifecycle ────────────────────────────────────────────

  @tag :acceptance
  test "stream lifecycle (create, wait, close with conservation)" do
    payer = create_test_wallet()
    payee = create_test_wallet()
    fund_wallet(payer, 100)

    contracts = fetch_contracts()

    # Sign permit for the Stream contract
    deadline = :os.system_time(:second) + 3600
    permit = sign_usdc_permit(
      payer.key_hex, payer.wallet.address, contracts["stream"],
      10_000_000, 0, deadline
    )

    payer_before = get_usdc_balance(payer.wallet.address)

    # 1. Create stream: $0.01/sec, $5 max
    {:ok, stream} = Wallet.create_stream(payer.wallet, payee.wallet.address,
      "0.01", "5.0", permit: permit)
    assert stream.stream_id != nil

    # Wait for on-chain lock
    wait_for_balance_change(payer.wallet.address, payer_before)

    # 2. Let it run for a few seconds
    Process.sleep(5_000)

    # 3. Close stream
    {:ok, closed} = Wallet.close_stream(payer.wallet, stream.stream_id)
    assert %RemitMd.Models.Stream{} = closed

    # 4. Conservation: payer should have lost some funds
    payer_after = wait_for_balance_change(payer.wallet.address, payer_before)
    payer_delta = payer_after - payer_before
    assert payer_delta < 0
  end

  # ─── Test: Bounty Lifecycle ────────────────────────────────────────────

  @tag :acceptance
  test "bounty lifecycle (create, submit, award)" do
    poster = create_test_wallet()
    submitter = create_test_wallet()
    fund_wallet(poster, 100)

    contracts = fetch_contracts()

    # Sign permit for the Bounty contract
    deadline_permit = :os.system_time(:second) + 3600
    permit = sign_usdc_permit(
      poster.key_hex, poster.wallet.address, contracts["bounty"],
      10_000_000, 0, deadline_permit
    )

    poster_before = get_usdc_balance(poster.wallet.address)
    fee_before = get_fee_balance()

    # 1. Create bounty: $5 reward, 1 hour deadline
    bounty_deadline = :os.system_time(:second) + 3600
    {:ok, bounty} = Wallet.create_bounty(poster.wallet, "5.000000",
      "Write an Elixir acceptance test", bounty_deadline, permit: permit)
    assert bounty.bounty_id != nil

    # Wait for on-chain lock
    wait_for_balance_change(poster.wallet.address, poster_before)

    # 2. Submit evidence (as submitter)
    evidence_hash = "0x" <> (RemitMd.Keccak.hex("elixir test evidence"))
    {:ok, sub} = Wallet.submit_bounty(submitter.wallet, bounty.bounty_id, evidence_hash)
    assert sub.bounty_id == bounty.bounty_id

    # 3. Award bounty (as poster)
    {:ok, awarded} = Wallet.award_bounty(poster.wallet, bounty.bounty_id, sub.id)
    assert %RemitMd.Models.Bounty{} = awarded

    # 4. Verify: submitter should have received funds
    submitter_after = wait_for_balance_change(submitter.wallet.address, 0)
    assert submitter_after > 0

    fee_after = get_fee_balance()
    assert fee_after >= fee_before
  end

  # ─── Test: Deposit Lifecycle ───────────────────────────────────────────

  @tag :acceptance
  test "deposit lifecycle (place, return with full refund)" do
    payer = create_test_wallet()
    provider = create_test_wallet()
    fund_wallet(payer, 100)

    contracts = fetch_contracts()

    # Sign permit for the Deposit contract
    deadline = :os.system_time(:second) + 3600
    permit = sign_usdc_permit(
      payer.key_hex, payer.wallet.address, contracts["deposit"],
      10_000_000, 0, deadline
    )

    payer_before = get_usdc_balance(payer.wallet.address)

    # 1. Place deposit: $5, expires in 1 hour
    {:ok, deposit} = Wallet.place_deposit(payer.wallet, provider.wallet.address, "5.000000",
      expires_in: 3600, permit: permit)
    assert deposit.deposit_id != nil

    # Wait for on-chain lock
    wait_for_balance_change(payer.wallet.address, payer_before)
    payer_after_deposit = get_usdc_balance(payer.wallet.address)

    # 2. Return deposit (by provider)
    {:ok, _} = Wallet.return_deposit(provider.wallet, deposit.deposit_id)

    # 3. Verify full refund (deposits have no fee)
    payer_after_return = wait_for_balance_change(payer.wallet.address, payer_after_deposit)
    refund_amount = payer_after_return - payer_after_deposit
    assert refund_amount >= 4.99,
      "expected near-full refund (~5.0), got #{refund_amount}"
  end

  # ─── Test: X402 Auto-Pay ──────────────────────────────────────────────

  @tag :acceptance
  test "x402 auto-pay (local server with 402)" do
    provider_wallet = create_test_wallet()

    # Build the PAYMENT-REQUIRED header payload
    api_base = if String.ends_with?(@api_url, "/api/v1"), do: @api_url, else: "#{@api_url}/api/v1"
    payment_payload = %{
      "payTo"       => provider_wallet.wallet.address,
      "amount"      => "1000",
      "network"     => "eip155:84532",
      "asset"       => @usdc_address,
      "facilitator" => api_base,
      "maxTimeout"  => 60,
      "resource"    => "/v1/data",
      "description" => "Test data endpoint",
      "mimeType"    => "application/json"
    }
    encoded_header = Base.encode64(Jason.encode!(payment_payload))

    # Start a local HTTP server that returns 402
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)
    server_url = "http://127.0.0.1:#{port}"

    # Spawn a simple HTTP server
    server_pid = spawn_link(fn -> accept_loop(listen_socket, encoded_header) end)

    try do
      # 1. Make a request without payment — should get 402
      :inets.start()
      :ssl.start()
      {:ok, {{_, status, _}, resp_headers, _body}} =
        :httpc.request(:get, {String.to_charlist("#{server_url}/v1/data"), []},
                       [{:timeout, 5_000}], [])
      assert status == 402

      # 2. Verify PAYMENT-REQUIRED header is present and parseable
      pay_req = :proplists.get_value(~c"payment-required", resp_headers)
      assert pay_req != :undefined
      decoded = Jason.decode!(Base.decode64!(to_string(pay_req)))
      assert decoded["payTo"] == provider_wallet.wallet.address
      assert decoded["resource"] == "/v1/data"
      assert decoded["description"] == "Test data endpoint"
      assert decoded["mimeType"] == "application/json"

      # 3. Make a request WITH a payment header — should get 200
      {:ok, {{_, status2, _}, _, resp_body2}} =
        :httpc.request(:get,
          {String.to_charlist("#{server_url}/v1/data"),
           [{~c"x-payment", ~c"test-payment-token"}]},
          [{:timeout, 5_000}], [])
      assert status2 == 200
      body_parsed = Jason.decode!(to_string(resp_body2))
      assert body_parsed["status"] == "ok"
      assert body_parsed["data"] == "secret"
    after
      Process.exit(server_pid, :kill)
      :gen_tcp.close(listen_socket)
    end
  end

  # Simple HTTP server for x402 test
  defp accept_loop(listen_socket, encoded_header) do
    case :gen_tcp.accept(listen_socket, 5_000) do
      {:ok, client} ->
        {:ok, data} = :gen_tcp.recv(client, 0, 5_000)
        request_str = to_string(data)

        has_payment = String.contains?(String.downcase(request_str), "x-payment:")

        if has_payment do
          body = ~s({"status":"ok","data":"secret"})
          response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
          :gen_tcp.send(client, response)
        else
          body = ~s({"error":"payment required"})
          response = "HTTP/1.1 402 Payment Required\r\nPayment-Required: #{encoded_header}\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
          :gen_tcp.send(client, response)
        end

        :gen_tcp.close(client)
        accept_loop(listen_socket, encoded_header)

      {:error, :timeout} ->
        accept_loop(listen_socket, encoded_header)

      {:error, _} ->
        :ok
    end
  end
end
