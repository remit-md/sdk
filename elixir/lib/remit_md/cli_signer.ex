defmodule RemitMd.CliSigner do
  @moduledoc """
  Signer backed by the `remit` CLI binary.

  Delegates EIP-712 signing to the `remit sign` subprocess. The CLI
  holds the encrypted keystore; this adapter only needs the binary on
  PATH and the `REMIT_KEY_PASSWORD` env var set.

  - No key material in this process -- signing happens in a subprocess.
  - Address is cached at construction time via `remit address`.
  - `sign/2` pipes the hex digest to `remit sign --digest` on stdin.
  - All errors are explicit -- no silent fallbacks.

  ## Usage

      {:ok, signer} = RemitMd.CliSigner.new()
      wallet = RemitMd.Wallet.new(signer: signer, chain: "base")
  """

  @behaviour RemitMd.Signer

  alias RemitMd.Error

  @enforce_keys [:address, :cli_path]
  defstruct [:address, :cli_path]

  @doc """
  Create a CliSigner by running `remit address` and caching the result.

  Returns `{:ok, signer}` or `{:error, reason}`.
  """
  def new(cli_path \\ "remit") do
    case System.cmd(cli_path, ["address"], stderr_to_stdout: true) do
      {output, 0} ->
        address = String.trim(output)

        unless String.starts_with?(address, "0x") and String.length(address) == 42 do
          {:error, "CliSigner: invalid address from CLI: #{address}"}
        else
          {:ok, %__MODULE__{address: address, cli_path: cli_path}}
        end

      {output, _exit_code} ->
        {:error, "CliSigner: failed to get address: #{String.trim(output)}"}
    end
  rescue
    e in ErlangError ->
      {:error, "CliSigner: CLI not found: #{inspect(e)}"}
  end

  @impl true
  def sign(%__MODULE__{cli_path: cli_path}, digest)
      when is_binary(digest) and byte_size(digest) == 32 do
    digest_hex = "0x" <> Base.encode16(digest, case: :lower)

    case System.cmd(cli_path, ["sign", "--digest"], input: digest_hex, stderr_to_stdout: true) do
      {output, 0} ->
        sig = String.trim(output)

        unless String.starts_with?(sig, "0x") and String.length(sig) == 132 do
          raise Error.new(
            Error.server_error(),
            "CliSigner: invalid signature from CLI: #{sig}"
          )
        end

        sig

      {output, _exit_code} ->
        raise Error.new(
          Error.server_error(),
          "CliSigner: signing failed: #{String.trim(output)}"
        )
    end
  end

  @impl true
  def address(%__MODULE__{address: addr}), do: addr

  @doc """
  Check conditions for CliSigner activation.

  1. CLI binary found on PATH
  2. Meta file at `~/.remit/keys/default.meta` (keychain -- no password needed), OR
  3. Keystore file at `~/.remit/keys/default.enc` AND `REMIT_KEY_PASSWORD` env var set
  """
  def available?(cli_path \\ "remit") do
    cli_exists?(cli_path) and (meta_exists?() or (keystore_exists?() and password_set?()))
  end

  defp cli_exists?(cli_path) do
    System.find_executable(cli_path) != nil
  end

  defp meta_exists? do
    home = System.user_home!()
    meta = Path.join([home, ".remit", "keys", "default.meta"])
    File.exists?(meta)
  end

  defp keystore_exists? do
    home = System.user_home!()
    keystore = Path.join([home, ".remit", "keys", "default.enc"])
    File.exists?(keystore)
  end

  defp password_set? do
    System.get_env("REMIT_KEY_PASSWORD") != nil
  end

  # ─── Protocol implementations ──────────────────────────────────────────────

  defimpl Inspect do
    def inspect(%RemitMd.CliSigner{address: addr}, _opts) do
      "#RemitMd.CliSigner<address=#{addr}>"
    end
  end

  defimpl String.Chars do
    def to_string(%RemitMd.CliSigner{address: addr}) do
      "#RemitMd.CliSigner<address=#{addr}>"
    end
  end
end
