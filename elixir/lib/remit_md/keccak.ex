defmodule RemitMd.Keccak do
  @moduledoc false
  import Bitwise
  # Pure Elixir Keccak-256 (Ethereum variant - NOT SHA-3).
  # Used for Ethereum address derivation from secp256k1 public keys.
  #
  # Reference: https://keccak.team/keccak_specs_summary.html
  # Rate = 1088 bits (136 bytes), Capacity = 512 bits, Output = 256 bits.
  # Keccak padding: 0x01 ... 0x80 (differs from SHA-3 which uses 0x06 ... 0x80)

  @rate_bytes 136

  # Round constants (24 rounds)
  @rc [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
  ]

  # ρ rotation offsets indexed by linear position 1..24 (position 0 stays at 0).
  # Linear index i maps to (x,y) = (rem(i,5), div(i,5)).
  @rho [1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14]

  # π destination indexed by linear position 1..24.
  # π: source (x,y) → dest (y, (2x+3y) mod 5), dest_index = y + 5*((2x+3y) mod 5).
  @pi [10, 20, 5, 15, 16, 1, 11, 21, 6, 7, 17, 2, 12, 22, 23, 8, 18, 3, 13, 14, 24, 9, 19, 4]

  @mask64 0xFFFFFFFFFFFFFFFF

  @doc """
  Compute the Keccak-256 hash of binary data.
  Returns a 32-byte binary.
  """
  def hash(data) when is_binary(data) do
    padded = pad(data)
    state = Tuple.duplicate(0, 25)
    state = absorb(state, padded, 0, byte_size(padded))
    squeeze(state)
  end

  @doc """
  Compute the Keccak-256 hash and return it as a 64-character lowercase hex string.
  """
  def hex(data) when is_binary(data) do
    data |> hash() |> Base.encode16(case: :lower)
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp pad(msg) do
    rate = @rate_bytes
    n = byte_size(msg)
    q = rate - rem(n, rate)

    if q == 1 do
      msg <> <<0x81>>
    else
      msg <> <<0x01>> <> :binary.copy(<<0>>, q - 2) <> <<0x80>>
    end
  end

  defp absorb(state, _data, offset, total) when offset >= total, do: state

  defp absorb(state, data, offset, total) do
    rate = @rate_bytes
    lane_count = div(rate, 8)

    state =
      Enum.reduce(0..(lane_count - 1), state, fn i, acc ->
        lane_offset = offset + i * 8
        <<lane::little-unsigned-integer-64>> = binary_part(data, lane_offset, 8)
        old = elem(acc, i)
        put_elem(acc, i, bxor(old, lane))
      end)

    state = keccak_f1600(state)
    absorb(state, data, offset + rate, total)
  end

  defp squeeze(state) do
    for i <- 0..3 do
      lane = elem(state, i)
      <<lane::little-unsigned-integer-64>>
    end
    |> IO.iodata_to_binary()
  end

  defp keccak_f1600(state) do
    Enum.reduce(@rc, state, fn rc, s -> round_fn(s, rc) end)
  end

  defp round_fn(state, rc) do
    mask = @mask64

    # ── Theta ──────────────────────────────────────────────────────────────
    c = {
      bxor5(state, 0),
      bxor5(state, 1),
      bxor5(state, 2),
      bxor5(state, 3),
      bxor5(state, 4)
    }

    d = {
      bxor(elem(c, 4), rotl64(elem(c, 1), 1)),
      bxor(elem(c, 0), rotl64(elem(c, 2), 1)),
      bxor(elem(c, 1), rotl64(elem(c, 3), 1)),
      bxor(elem(c, 2), rotl64(elem(c, 4), 1)),
      bxor(elem(c, 3), rotl64(elem(c, 0), 1))
    }

    state =
      Enum.reduce(0..24, state, fn i, acc ->
        put_elem(acc, i, bxor(elem(acc, i), elem(d, rem(i, 5))))
      end)

    # ── Rho + Pi ───────────────────────────────────────────────────────────
    # Combined: b[pi[i]] = rotl(a[i], rho[i-1]) for i in 1..24; b[0] = a[0]
    pi_rho = Enum.zip(@pi, @rho)

    b =
      pi_rho
      |> Enum.with_index(1)
      |> Enum.reduce(
        put_elem(Tuple.duplicate(0, 25), 0, elem(state, 0)),
        fn {{pi_dst, rho_bits}, src_idx}, acc ->
          put_elem(acc, pi_dst, rotl64(elem(state, src_idx), rho_bits))
        end
      )

    # ── Chi ────────────────────────────────────────────────────────────────
    state =
      Enum.reduce(0..4, Tuple.duplicate(0, 25), fn y, acc ->
        row = y * 5

        Enum.reduce(0..4, acc, fn x, acc2 ->
          i = row + x
          b0 = elem(b, i)
          b1 = elem(b, row + rem(x + 1, 5))
          b2 = elem(b, row + rem(x + 2, 5))
          put_elem(acc2, i, band(bxor(b0, band(bnot(b1), b2)), mask))
        end)
      end)

    # ── Iota ───────────────────────────────────────────────────────────────
    put_elem(state, 0, band(bxor(elem(state, 0), rc), mask))
  end

  # XOR all 5 lanes in column x (a[x], a[x+5], a[x+10], a[x+15], a[x+20])
  defp bxor5(state, x) do
    elem(state, x)
    |> bxor(elem(state, x + 5))
    |> bxor(elem(state, x + 10))
    |> bxor(elem(state, x + 15))
    |> bxor(elem(state, x + 20))
  end

  # 64-bit left rotation
  defp rotl64(x, n) do
    band(bor(x <<< n, x >>> (64 - n)), @mask64)
  end
end
