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
  Sign a 32-byte EIP-712 digest. Returns a 0x-prefixed 65-byte hex signature (r+s+v).
  v is 27 or 28 (Ethereum convention).

  The first argument is the signer struct, the second is the 32-byte digest to sign.
  """
  @callback sign(signer :: term(), digest :: binary()) :: String.t()

  @doc """
  Sign a raw 32-byte hash. Returns a 0x-prefixed 65-byte hex signature (r+s+v).

  Used by server-side signing flows (`/permits/prepare`, `/x402/prepare`)
  where the server computes the EIP-712 hash and the SDK only signs it.
  """
  @callback sign_hash(signer :: term(), hash :: binary()) :: String.t()

  @doc """
  Return the Ethereum address (0x-prefixed, 40 hex chars) for this signer.

  The argument is the signer struct.
  """
  @callback address(signer :: term()) :: String.t()
end

defmodule RemitMd.MockSigner do
  @moduledoc """
  A signer that returns a fixed fake signature. Used by `RemitMd.MockRemit` -
  the mock API server does not verify signatures.
  """

  @behaviour RemitMd.Signer

  def new(address \\ "0xDeAdBeEf00000000000000000000000000000001") do
    %{__struct__: __MODULE__, address: address}
  end

  @impl true
  def sign(_signer, _message), do: "0x" <> String.duplicate("ab", 65)

  @impl true
  def sign_hash(_signer, _hash), do: "0x" <> String.duplicate("ab", 65)

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

  # secp256k1 curve parameters
  @p 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
  @n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
  @gx 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
  @gy 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

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
  def sign(%__MODULE__{__key__: key_bytes, address: signer_addr}, digest)
      when is_binary(digest) and byte_size(digest) == 32 do
    # Sign the raw 32-byte EIP-712 digest (no additional hashing).
    # Use {:digest, digest} to tell :crypto the data is already hashed.
    der = :crypto.sign(:ecdsa, :sha256, {:digest, digest}, [key_bytes, :secp256k1])
    {r, s} = parse_der(der)

    # Normalize s to low-s canonical form (s <= n/2) to match RFC 6979 / Ethereum convention
    half_n = div(@n, 2)
    s = if s > half_n, do: @n - s, else: s

    # Compute recovery ID by checking which parity recovers our address
    z = :binary.decode_unsigned(digest)
    v = recover_v(r, s, z, signer_addr)

    # Build 65-byte Ethereum signature: r(32) || s(32) || v(1)
    sig = <<r::unsigned-big-integer-size(256), s::unsigned-big-integer-size(256), v>>
    "0x" <> Base.encode16(sig, case: :lower)
  end

  @impl true
  def sign_hash(%__MODULE__{} = signer, hash)
      when is_binary(hash) and byte_size(hash) == 32 do
    sign(signer, hash)
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
    {pub_key, _priv} = :crypto.generate_key(:ecdh, :secp256k1, private_key_bytes)

    pub_uncompressed =
      case byte_size(pub_key) do
        65 -> pub_key
        33 -> decompress_public_key(pub_key)
      end

    <<0x04, pub_64::binary-size(64)>> = pub_uncompressed
    keccak_hash = RemitMd.Keccak.hash(pub_64)
    <<_prefix::binary-size(12), address_bytes::binary-size(20)>> = keccak_hash
    "0x" <> Base.encode16(address_bytes, case: :lower)
  end

  # ─── DER parsing ─────────────────────────────────────────────────────────

  defp parse_der(<<0x30, _len, 0x02, r_len, rest::binary>>) do
    <<r_raw::binary-size(r_len), 0x02, s_len, s_rest::binary>> = rest
    <<s_raw::binary-size(s_len), _::binary>> = s_rest
    r = :binary.decode_unsigned(strip_leading_zero(r_raw))
    s = :binary.decode_unsigned(strip_leading_zero(s_raw))
    {r, s}
  end

  defp strip_leading_zero(<<0, rest::binary>>), do: rest
  defp strip_leading_zero(bin), do: bin

  # ─── ECDSA v recovery ────────────────────────────────────────────────────

  defp recover_v(r, s, z, expected_addr) do
    r_inv = modinv(r, @n)
    a = Integer.mod(r_inv * s, @n)
    b = Integer.mod(@n - Integer.mod(r_inv * z, @n), @n)

    Enum.find_value([0, 1], fn parity ->
      case recover_r_point(r, parity) do
        nil ->
          nil

        r_point ->
          # Q = a*R + b*G
          ar = ec_mul(a, r_point)
          bg = ec_mul(b, {@gx, @gy})
          q = ec_add(ar, bg)

          case q do
            :infinity ->
              nil

            point ->
              addr = point_to_address(point)

              if String.downcase(addr) == String.downcase(expected_addr) do
                27 + parity
              end
          end
      end
    end) || raise "Could not determine ECDSA recovery ID"
  end

  defp recover_r_point(r, parity) do
    y_squared = Integer.mod(pow_mod(r, 3, @p) + 7, @p)
    y_candidate = pow_mod(y_squared, div(@p + 1, 4), @p)

    if Integer.mod(y_candidate * y_candidate, @p) != y_squared do
      nil
    else
      y = if Integer.mod(y_candidate, 2) == parity, do: y_candidate, else: @p - y_candidate
      {r, y}
    end
  end

  defp point_to_address({x, y}) do
    pub_64 = <<x::unsigned-big-integer-size(256), y::unsigned-big-integer-size(256)>>
    keccak_hash = RemitMd.Keccak.hash(pub_64)
    <<_prefix::binary-size(12), address_bytes::binary-size(20)>> = keccak_hash
    "0x" <> Base.encode16(address_bytes, case: :lower)
  end

  # ─── EC point arithmetic on secp256k1 ────────────────────────────────────

  defp ec_add(:infinity, q), do: q
  defp ec_add(p, :infinity), do: p

  defp ec_add({x1, y1}, {x2, y2}) do
    if x1 == x2 do
      if y1 == y2, do: ec_double({x1, y1}), else: :infinity
    else
      lam = Integer.mod((y2 - y1) * modinv(x2 - x1, @p), @p)
      x3 = Integer.mod(lam * lam - x1 - x2, @p)
      y3 = Integer.mod(lam * (x1 - x3) - y1, @p)
      {x3, y3}
    end
  end

  defp ec_double(:infinity), do: :infinity

  defp ec_double({x, y}) do
    lam = Integer.mod(3 * x * x * modinv(2 * y, @p), @p)
    x3 = Integer.mod(lam * lam - 2 * x, @p)
    y3 = Integer.mod(lam * (x - x3) - y, @p)
    {x3, y3}
  end

  defp ec_mul(0, _p), do: :infinity
  defp ec_mul(k, point), do: do_ec_mul(k, point, :infinity)

  defp do_ec_mul(0, _p, acc), do: acc

  defp do_ec_mul(k, p, acc) do
    acc = if rem(k, 2) == 1, do: ec_add(acc, p), else: acc
    do_ec_mul(div(k, 2), ec_double(p), acc)
  end

  # Modular inverse via Fermat's little theorem (p and n are prime)
  defp modinv(a, m), do: pow_mod(Integer.mod(a + m, m), m - 2, m)

  # ─── secp256k1 public key decompression ──────────────────────────────────

  defp decompress_public_key(<<prefix, x_bytes::binary-size(32)>>) when prefix in [0x02, 0x03] do
    x = :binary.decode_unsigned(x_bytes)
    y_squared = Integer.mod(pow_mod(x, 3, @p) + 7, @p)
    y_candidate = pow_mod(y_squared, div(@p + 1, 4), @p)

    y =
      if rem(y_candidate, 2) == prefix - 2 do
        y_candidate
      else
        @p - y_candidate
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
