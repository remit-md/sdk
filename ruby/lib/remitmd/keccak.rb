# frozen_string_literal: true

module Remitmd
  # Pure-Ruby Keccak-256 (Ethereum variant — NOT SHA-3).
  #
  # SHA-3 uses different padding (0x06 instead of 0x01).
  # This implementation matches Ethereum's keccak256.
  #
  # Reference: https://keccak.team/keccak_specs_summary.html
  # Rate = 1088 bits (136 bytes), Capacity = 512 bits, Output = 256 bits.
  module Keccak
    RATE_BYTES = 136
    MASK64 = 0xFFFFFFFFFFFFFFFF

    RC = [
      0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
      0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
      0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
      0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
      0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
      0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
    ].freeze

    RHO = [
      1, 62, 28, 27, 36, 44, 6, 55, 20, 3,
      10, 43, 25, 39, 41, 45, 15, 21, 8, 18,
      2, 61, 56, 14
    ].freeze

    PI = [
      10, 20, 5, 15, 16, 1, 11, 21, 6, 7,
      17, 2, 12, 22, 23, 8, 18, 3, 13, 14,
      24, 9, 19, 4
    ].freeze

    class << self
      def digest(data)
        data = data.b if data.encoding != Encoding::BINARY
        padded = pad(data)
        state = Array.new(25, 0)
        offset = 0
        while offset < padded.bytesize
          absorb!(state, padded, offset)
          offset += RATE_BYTES
        end
        squeeze(state)
      end

      def hexdigest(data)
        digest(data).unpack1("H*")
      end

      private

      def pad(msg)
        q = RATE_BYTES - (msg.bytesize % RATE_BYTES)
        if q == 1
          msg + "\x81".b
        else
          msg + "\x01".b + ("\x00".b * (q - 2)) + "\x80".b
        end
      end

      def absorb!(state, data, offset)
        17.times do |i|
          lane = data.byteslice(offset + i * 8, 8).unpack1("Q<")
          state[i] ^= lane
        end
        keccak_f1600!(state)
      end

      def squeeze(state)
        state[0, 4].pack("Q<4")
      end

      def keccak_f1600!(state)
        RC.each { |rc| keccak_round!(state, rc) }
      end

      def keccak_round!(state, rc) # rubocop:disable Metrics/MethodLength
        # Theta
        c = Array.new(5) do |x|
          state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
        end
        d = Array.new(5) do |x|
          c[(x + 4) % 5] ^ rotl64(c[(x + 1) % 5], 1)
        end
        25.times { |i| state[i] ^= d[i % 5] }

        # Rho + Pi
        b = Array.new(25, 0)
        b[0] = state[0]
        24.times do |i|
          b[PI[i]] = rotl64(state[i + 1], RHO[i])
        end

        # Chi
        5.times do |y|
          row = y * 5
          5.times do |x|
            idx = row + x
            state[idx] = (b[idx] ^ ((~b[row + (x + 1) % 5]) & b[row + (x + 2) % 5])) & MASK64
          end
        end

        # Iota
        state[0] = (state[0] ^ rc) & MASK64
      end

      def rotl64(x, n)
        ((x << n) | (x >> (64 - n))) & MASK64
      end
    end
  end
end
