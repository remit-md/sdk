defmodule RemitMd.Signer do
  @moduledoc """
  Behaviour for signing remit.md API requests.

  Implement this behaviour to use a custom key management system
  (HSM, KMS, Ledger, etc.).

  ## Example

      defmodule MyKmsSigner do
        @behaviour RemitMd.Signer

        @impl true
        def sign(_signer, message), do: MyKms.sign_sha256(message)

        @impl true
        def address(_signer), do: "0xYourAgentAddress"
      end
  """

  @doc """
  Sign the given message binary. Returns a 0x-prefixed hex signature string.
  The implementation may hash the message as needed before signing.

  The first argument is the signer struct, the second is the message to sign.
  """
  @callback sign(signer :: term(), message :: binary()) :: String.t()

  @doc """
  Return the Ethereum address (0x-prefixed, 40 hex chars) for this signer.

  The argument is the signer struct.
  """
  @callback address(signer :: term()) :: String.t()
end

defmodule RemitMd.MockSigner do
  @moduledoc """
  A signer that returns a fixed fake signature. Used by `RemitMd.MockRemit` —
  the mock API server does not verify signatures.
  """

  @behaviour RemitMd.Signer

  def new(address \\ "0xDeAdBeEf00000000000000000000000000000001") do
    %{__struct__: __MODULE__, address: address}
  end

  @impl true
  def sign(_signer, _message), do: "0x" <> String.duplicate("ab", 65)

  @impl true
  def address(%{address: addr}), do: addr
end

defmodule RemitMd.PrivateKeySigner do
  @moduledoc """
  Signs API requests using a raw secp256k1 private key.

  The private key is held in memory and never exposed via public API,
  inspect/1, or to_string/1.

  Uses Erlang's `:crypto` module (stdlib, no external deps) for secp256k1
  operations and a vendored pure-Elixir Keccak-256 for address derivation.
  """

  @behaviour RemitMd.Signer

  @enforce_keys [:address, :__key__]
  defstruct [:address, :__key__]

  @doc """
  Create a signer from a 0x-prefixed or bare 64-character hex private key.
  """
  def new(private_key_hex) when is_binary(private_key_hex) do
    hex = String.trim_leading(private_key_hex, "0x")

    unless String.match?(hex, ~r/\A[0-9a-fA-F]{64}\z/) do
      raise RemitMd.Error.new(
        RemitMd.Error.invalid_amount(),
        "Private key must be 64 hex characters (got #{String.length(hex)})"
      )
    end

    key_bytes = Base.decode16!(hex, case: :mixed)
    address = derive_address(key_bytes)

    %__MODULE__{address: address, __key__: key_bytes}
  end

  @impl true
  def sign(%__MODULE__{__key__: key_bytes}, message) when is_binary(message) do
    # :crypto.sign(:ecdsa, :sha256, message, key, curve) computes sha256 internally
    # before signing with the secp256k1 private key.
    sig_der = :crypto.sign(:ecdsa, :sha256, message, [key_bytes, :secp256k1])
    "0x" <> Base.encode16(sig_der, case: :lower)
  end

  @impl true
  def address(%__MODULE__{address: addr}), do: addr

  defimpl Inspect do
    def inspect(%RemitMd.PrivateKeySigner{address: addr}, _opts) do
      "#RemitMd.PrivateKeySigner<address=#{addr}>"
    end
  end

  defimpl String.Chars do
    def to_string(%RemitMd.PrivateKeySigner{address: addr}) do
      "#RemitMd.PrivateKeySigner<address=#{addr}>"
    end
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp derive_address(private_key_bytes) do
    # Derive the uncompressed secp256k1 public key (65 bytes: 0x04 || x || y)
    {pub_key, _priv} = :crypto.generate_key(:ecdh, :secp256k1, private_key_bytes)

    # pub_key is the compressed (33 bytes) or uncompressed (65 bytes) form.
    # :crypto.generate_key with a supplied private key returns the public key.
    # For secp256k1 ECDH, it returns the compressed public key (33 bytes).
    # We need uncompressed (65 bytes) for address derivation.
    # Compute uncompressed from compressed using :crypto.
    pub_uncompressed =
      case byte_size(pub_key) do
        65 -> pub_key
        33 ->
          # Decompress: use :crypto.ec_point_mul (OTP 26+) or compute manually
          decompress_public_key(pub_key)
      end

    # Drop the 0x04 prefix, hash the remaining 64 bytes with Keccak-256
    <<0x04, pub_64::binary-size(64)>> = pub_uncompressed
    keccak_hash = RemitMd.Keccak.hash(pub_64)

    # Ethereum address = last 20 bytes of keccak hash
    <<_prefix::binary-size(12), address_bytes::binary-size(20)>> = keccak_hash
    "0x" <> Base.encode16(address_bytes, case: :lower)
  end

  # Decompress a secp256k1 compressed public key (33 bytes) to uncompressed (65 bytes).
  # secp256k1: y^2 = x^3 + 7 (mod p), p = 2^256 - 2^32 - 977
  defp decompress_public_key(<<prefix, x_bytes::binary-size(32)>>) when prefix in [0x02, 0x03] do
    p = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
    x = :binary.decode_unsigned(x_bytes)

    # y^2 = x^3 + 7 mod p
    y_squared = rem(pow_mod(x, 3, p) + 7, p)
    y_candidate = pow_mod(y_squared, div(p + 1, 4), p)

    y =
      if rem(y_candidate, 2) == prefix - 2 do
        y_candidate
      else
        p - y_candidate
      end

    y_bytes = <<y::unsigned-big-integer-size(256)>>
    <<0x04>> <> x_bytes <> y_bytes
  end

  # Modular exponentiation: base^exp mod m
  defp pow_mod(base, exp, m) do
    pow_mod(base, exp, m, 1)
  end

  defp pow_mod(_base, 0, _m, acc), do: acc

  defp pow_mod(base, exp, m, acc) do
    acc = if rem(exp, 2) == 1, do: rem(acc * base, m), else: acc
    pow_mod(rem(base * base, m), div(exp, 2), m, acc)
  end
end
