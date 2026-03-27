defmodule RemitMd.HttpSignerTest do
  use ExUnit.Case, async: false

  alias RemitMd.HttpSigner

  @mock_address "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  @mock_signature "0x" <> String.duplicate("ab", 32) <> String.duplicate("cd", 32) <> "1b"
  @valid_token "rmit_sk_test_token_abc123"

  # ─── Minimal mock HTTP server using :gen_tcp ───────────────────────────────

  defp start_mock_server(handler) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    pid = spawn_link(fn -> accept_loop(listen, handler) end)

    %{port: port, pid: pid, listen: listen}
  end

  defp accept_loop(listen, handler) do
    case :gen_tcp.accept(listen, 1000) do
      {:ok, socket} ->
        spawn(fn -> handle_connection(socket, handler) end)
        accept_loop(listen, handler)

      {:error, :timeout} ->
        accept_loop(listen, handler)

      {:error, :closed} ->
        :ok
    end
  end

  defp handle_connection(socket, handler) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} ->
        {method, path, body} = parse_request(data)
        {status, resp_body} = handler.(method, path, body, data)
        response = build_http_response(status, resp_body)
        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end

  defp parse_request(data) do
    lines = String.split(data, "\r\n")
    [request_line | _] = lines
    [method, path | _] = String.split(request_line, " ")

    # Extract body (after double CRLF)
    body =
      case String.split(data, "\r\n\r\n", parts: 2) do
        [_, body] -> body
        _ -> ""
      end

    {method, path, body}
  end

  defp build_http_response(status, body) do
    reason =
      case status do
        200 -> "OK"
        401 -> "Unauthorized"
        403 -> "Forbidden"
        500 -> "Internal Server Error"
        _ -> "Error"
      end

    "HTTP/1.1 #{status} #{reason}\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
  end

  defp mock_url(server), do: "http://127.0.0.1:#{server.port}"

  defp stop_server(server) do
    :gen_tcp.close(server.listen)
  end

  # ─── Default mock handler ──────────────────────────────────────────────────

  defp default_handler(method, path, _body, raw_data) do
    has_auth = String.contains?(raw_data, "Bearer #{@valid_token}")

    cond do
      !has_auth ->
        {401, Jason.encode!(%{error: "unauthorized"})}

      method == "GET" and path == "/address" ->
        {200, Jason.encode!(%{address: @mock_address})}

      method == "POST" and path == "/sign/digest" ->
        {200, Jason.encode!(%{signature: @mock_signature})}

      true ->
        {404, Jason.encode!(%{error: "not_found"})}
    end
  end

  # ─── Tests ─────────────────────────────────────────────────────────────────

  describe "happy path" do
    test "new/2 fetches and caches address, sign/2 returns signature" do
      server = start_mock_server(&default_handler/4)

      signer = HttpSigner.new(mock_url(server), @valid_token)
      assert HttpSigner.address(signer) == @mock_address

      # Sign a 32-byte digest
      digest = :crypto.strong_rand_bytes(32)
      sig = HttpSigner.sign(signer, digest)
      assert sig == @mock_signature
      assert String.starts_with?(sig, "0x")

      stop_server(server)
    end

    test "new/2 strips trailing slash from URL" do
      server = start_mock_server(&default_handler/4)

      signer = HttpSigner.new(mock_url(server) <> "/", @valid_token)
      assert HttpSigner.address(signer) == @mock_address

      stop_server(server)
    end
  end

  describe "unreachable server" do
    test "new/2 raises NETWORK_ERROR when server is unreachable" do
      assert_raise RemitMd.Error, ~r/cannot reach signer server/, fn ->
        HttpSigner.new("http://127.0.0.1:1", @valid_token)
      end
    end
  end

  describe "401 unauthorized" do
    test "new/2 raises UNAUTHORIZED with bad token" do
      server = start_mock_server(&default_handler/4)

      error = assert_raise RemitMd.Error, ~r/unauthorized/, fn ->
        HttpSigner.new(mock_url(server), "wrong_token")
      end

      assert error.code == "UNAUTHORIZED"

      stop_server(server)
    end

    test "sign/2 raises UNAUTHORIZED when sign endpoint returns 401" do
      handler = fn method, path, body, raw_data ->
        # Accept address but reject sign
        cond do
          method == "GET" and path == "/address" ->
            {200, Jason.encode!(%{address: @mock_address})}

          method == "POST" and path == "/sign/digest" ->
            {401, Jason.encode!(%{error: "unauthorized"})}

          true ->
            default_handler(method, path, body, raw_data)
        end
      end

      server = start_mock_server(handler)

      signer = HttpSigner.new(mock_url(server), @valid_token)
      digest = :crypto.strong_rand_bytes(32)

      error = assert_raise RemitMd.Error, ~r/unauthorized/, fn ->
        HttpSigner.sign(signer, digest)
      end

      assert error.code == "UNAUTHORIZED"

      stop_server(server)
    end
  end

  describe "403 policy denied" do
    test "sign/2 raises FORBIDDEN with reason from server" do
      handler = fn method, path, body, raw_data ->
        cond do
          method == "GET" and path == "/address" ->
            {200, Jason.encode!(%{address: @mock_address})}

          method == "POST" and path == "/sign/digest" ->
            {403, Jason.encode!(%{error: "policy_denied", reason: "chain not allowed"})}

          true ->
            default_handler(method, path, body, raw_data)
        end
      end

      server = start_mock_server(handler)

      signer = HttpSigner.new(mock_url(server), @valid_token)
      digest = :crypto.strong_rand_bytes(32)

      error = assert_raise RemitMd.Error, ~r/policy denied/, fn ->
        HttpSigner.sign(signer, digest)
      end

      assert error.code == "FORBIDDEN"
      assert String.contains?(error.message, "chain not allowed")

      stop_server(server)
    end
  end

  describe "500 server error" do
    test "sign/2 raises SERVER_ERROR on 500" do
      handler = fn method, path, body, raw_data ->
        cond do
          method == "GET" and path == "/address" ->
            {200, Jason.encode!(%{address: @mock_address})}

          method == "POST" and path == "/sign/digest" ->
            {500, Jason.encode!(%{error: "internal_error"})}

          true ->
            default_handler(method, path, body, raw_data)
        end
      end

      server = start_mock_server(handler)

      signer = HttpSigner.new(mock_url(server), @valid_token)
      digest = :crypto.strong_rand_bytes(32)

      error = assert_raise RemitMd.Error, ~r/POST \/sign\/digest failed/, fn ->
        HttpSigner.sign(signer, digest)
      end

      assert error.code == "SERVER_ERROR"

      stop_server(server)
    end
  end

  describe "malformed response" do
    test "sign/2 raises SERVER_ERROR on non-JSON response" do
      handler = fn method, path, body, raw_data ->
        cond do
          method == "GET" and path == "/address" ->
            {200, Jason.encode!(%{address: @mock_address})}

          method == "POST" and path == "/sign/digest" ->
            {200, "this is not json"}

          true ->
            default_handler(method, path, body, raw_data)
        end
      end

      server = start_mock_server(handler)

      signer = HttpSigner.new(mock_url(server), @valid_token)
      digest = :crypto.strong_rand_bytes(32)

      error = assert_raise RemitMd.Error, ~r/invalid JSON/, fn ->
        HttpSigner.sign(signer, digest)
      end

      assert error.code == "SERVER_ERROR"

      stop_server(server)
    end

    test "sign/2 raises SERVER_ERROR when response has no signature field" do
      handler = fn method, path, body, raw_data ->
        cond do
          method == "GET" and path == "/address" ->
            {200, Jason.encode!(%{address: @mock_address})}

          method == "POST" and path == "/sign/digest" ->
            {200, Jason.encode!(%{wrong_field: "value"})}

          true ->
            default_handler(method, path, body, raw_data)
        end
      end

      server = start_mock_server(handler)

      signer = HttpSigner.new(mock_url(server), @valid_token)
      digest = :crypto.strong_rand_bytes(32)

      error = assert_raise RemitMd.Error, ~r/no signature/, fn ->
        HttpSigner.sign(signer, digest)
      end

      assert error.code == "SERVER_ERROR"

      stop_server(server)
    end

    test "new/2 raises SERVER_ERROR when address response has no address field" do
      handler = fn _method, _path, _body, _raw_data ->
        {200, Jason.encode!(%{wrong: "field"})}
      end

      server = start_mock_server(handler)

      error = assert_raise RemitMd.Error, ~r/returned no address/, fn ->
        HttpSigner.new(mock_url(server), @valid_token)
      end

      assert error.code == "SERVER_ERROR"

      stop_server(server)
    end
  end

  describe "token safety" do
    test "inspect does not leak token" do
      server = start_mock_server(&default_handler/4)

      signer = HttpSigner.new(mock_url(server), @valid_token)
      inspected = inspect(signer)

      refute String.contains?(inspected, @valid_token)
      assert String.contains?(inspected, "HttpSigner")
      assert String.contains?(inspected, @mock_address)

      stop_server(server)
    end

    test "to_string does not leak token" do
      server = start_mock_server(&default_handler/4)

      signer = HttpSigner.new(mock_url(server), @valid_token)
      stringified = to_string(signer)

      refute String.contains?(stringified, @valid_token)
      assert String.contains?(stringified, "HttpSigner")
      assert String.contains?(stringified, @mock_address)

      stop_server(server)
    end
  end

  describe "from_env integration" do
    setup do
      # Clean up env vars after each test
      on_exit(fn ->
        System.delete_env("REMIT_SIGNER_URL")
        System.delete_env("REMIT_SIGNER_TOKEN")
        System.delete_env("REMITMD_KEY")
        System.delete_env("REMITMD_PRIVATE_KEY")
        System.delete_env("REMITMD_CHAIN")
        System.delete_env("REMITMD_API_URL")
        System.delete_env("REMITMD_ROUTER_ADDRESS")
      end)

      :ok
    end

    test "from_env raises when REMIT_SIGNER_URL is set but REMIT_SIGNER_TOKEN is missing" do
      System.put_env("REMIT_SIGNER_URL", "http://127.0.0.1:7402")
      System.delete_env("REMIT_SIGNER_TOKEN")
      System.delete_env("REMITMD_KEY")

      assert_raise RemitMd.Error, ~r/REMIT_SIGNER_TOKEN is missing/, fn ->
        RemitMd.Wallet.from_env()
      end
    end

    test "from_env raises clear error when no credentials are set" do
      System.delete_env("REMIT_SIGNER_URL")
      System.delete_env("REMITMD_KEY")
      System.delete_env("REMITMD_PRIVATE_KEY")

      assert_raise RemitMd.Error, ~r/No signing credentials found/, fn ->
        RemitMd.Wallet.from_env()
      end
    end

    test "from_env with REMIT_SIGNER_URL creates HttpSigner-backed wallet" do
      server = start_mock_server(&default_handler/4)

      System.put_env("REMIT_SIGNER_URL", mock_url(server))
      System.put_env("REMIT_SIGNER_TOKEN", @valid_token)
      System.delete_env("REMITMD_KEY")

      wallet = RemitMd.Wallet.from_env()
      assert wallet.address == @mock_address
      assert %RemitMd.HttpSigner{} = wallet.signer

      stop_server(server)
    end
  end
end
