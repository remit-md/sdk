# frozen_string_literal: true

require "openssl"
require "securerandom"

module Remitmd
  # secp256k1 field prime p (constant — never changes)
  SECP256K1_P = OpenSSL::BN.new(
    "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F", 16
  ).freeze

  # Precomputed (p + 1) / 4 — the modular square root exponent for p ≡ 3 (mod 4).
  # Avoids BN division at runtime (which returns Integer on some OpenSSL versions).
  SECP256K1_SQRT_EXP = OpenSSL::BN.new(
    "3FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFBFFFFF0C", 16
  ).freeze

  # Interface for signing remit.md API requests.
  # Implement this module to provide custom signing (HSM, KMS, etc.).
  module Signer
    # Sign a 32-byte digest (raw binary). Returns 65-byte hex (r||s||v, Ethereum style).
    def sign(digest)
      raise NotImplementedError, "#{self.class}#sign is not implemented"
    end

    # The Ethereum address corresponding to the signing key (0x-prefixed).
    def address
      raise NotImplementedError, "#{self.class}#address is not implemented"
    end
  end

  # Signs remit.md API requests using a raw secp256k1 private key.
  # The private key is held in memory and never exposed via public methods.
  class PrivateKeySigner
    include Signer

    def initialize(private_key_hex)
      hex = private_key_hex.to_s.delete_prefix("0x")
      raise ArgumentError, "Private key must be 64 hex characters" unless hex.match?(/\A[0-9a-fA-F]{64}\z/)

      key_bytes = [hex].pack("H*")
      group = OpenSSL::PKey::EC::Group.new("secp256k1")
      bn = OpenSSL::BN.new(key_bytes, 2)
      pub_point = group.generator.mul(bn)

      # Build SEC1 DER-encoded private key (OpenSSL 3.x: PKey objects are immutable)
      asn1 = OpenSSL::ASN1::Sequence.new([
        OpenSSL::ASN1::Integer.new(1),
        OpenSSL::ASN1::OctetString.new(key_bytes),
        OpenSSL::ASN1::ASN1Data.new(
          [OpenSSL::ASN1::ObjectId.new("secp256k1")], 0, :CONTEXT_SPECIFIC
        ),
        OpenSSL::ASN1::ASN1Data.new(
          [OpenSSL::ASN1::BitString.new(pub_point.to_octet_string(:uncompressed))],
          1, :CONTEXT_SPECIFIC
        )
      ])
      @key = OpenSSL::PKey::EC.new(asn1.to_der)
      @address = derive_address(pub_point)
    end

    # Sign a 32-byte EIP-712 digest (raw binary bytes).
    # Returns a 0x-prefixed 65-byte hex signature (r || s || v) in Ethereum style.
    # v is 27 (0x1b) or 28 (0x1c).
    def sign(digest_bytes)
      group = @key.group
      n     = group.order

      # ECDSA sign — dsa_sign_asn1 uses the input directly as the hash (no pre-hashing)
      der  = @key.dsa_sign_asn1(digest_bytes)
      asn1 = OpenSSL::ASN1.decode(der)
      bn_r = asn1.value[0].value
      bn_s = asn1.value[1].value

      # Compute the recovery ID (0 or 1) by checking which candidate R recovers our address.
      z     = OpenSSL::BN.new(digest_bytes.unpack1("H*"), 16)
      r_inv = bn_r.mod_inverse(n)
      # Q_candidate = r_inv * (s * R - z * G) = (r_inv*s)*R + (-(r_inv*z))*G
      a = r_inv.mod_mul(bn_s, n)
      b = n - r_inv.mod_mul(z, n)   # -r_inv*z mod n

      v = nil
      [0, 1].each do |parity|
        r_point = recover_r_point(group, bn_r, parity)
        next unless r_point

        # group.generator.mul(scalar_for_G, [scalar_for_R], [R_point])
        # computes: scalar_for_G * G + scalar_for_R * R_point
        q = group.generator.mul(b, [a], [r_point])
        candidate = derive_address(q)
        if candidate.downcase == @address.downcase
          v = 27 + parity
          break
        end
      end
      raise "Could not determine recovery ID — key or hash may be invalid" if v.nil?

      # Build 65-byte Ethereum signature: r (32) || s (32) || v (1)
      r_bytes = [bn_r.to_s(16).rjust(64, "0")].pack("H*")
      s_bytes = [bn_s.to_s(16).rjust(64, "0")].pack("H*")
      "0x#{(r_bytes + s_bytes + v.chr(Encoding::BINARY)).unpack1("H*")}"
    end

    # The Ethereum address (checksummed, 0x-prefixed).
    attr_reader :address

    # Never expose the key in inspect/to_s output.
    def inspect
      "#<Remitmd::PrivateKeySigner address=#{@address}>"
    end

    alias to_s inspect

    private

    # Recover the secp256k1 point R from r (big integer) and y-parity (0=even, 1=odd).
    # Returns nil if the point is invalid.
    def recover_r_point(group, bn_r, parity)
      p = SECP256K1_P
      x = bn_r
      # y² = x³ + 7 (mod p)  — secp256k1 curve equation
      x3  = x.mod_exp(OpenSSL::BN.new("3"), p)
      rhs = x3 + OpenSSL::BN.new("7")
      y_squared = rhs % p
      # Tonelli–Shanks: since p ≡ 3 mod 4, sqrt = y²^((p+1)/4) mod p
      y = y_squared.mod_exp(SECP256K1_SQRT_EXP, p)
      # Verify that y² ≡ y_squared (mod p) — i.e., a square root exists
      return nil unless y.mod_mul(y, p) == y_squared

      y = p - y if (y.to_i & 1) != parity

      hex_x = x.to_s(16).rjust(64, "0")
      hex_y = y.to_s(16).rjust(64, "0")
      OpenSSL::PKey::EC::Point.new(group, OpenSSL::BN.new("04#{hex_x}#{hex_y}", 16))
    rescue OpenSSL::PKey::ECError
      nil
    end

    def derive_address(public_key)
      # Uncompressed public key: 04 || x (32) || y (32) — skip the 0x04 prefix
      pub_bytes = [public_key.to_octet_string(:uncompressed).unpack1("H*")[2..]].pack("H*")
      keccak    = keccak256_hex(pub_bytes)
      "0x#{keccak[-40..]}"
    end

    # Returns the keccak256 digest as a hex string (no 0x prefix).
    def keccak256_hex(data)
      Remitmd::Keccak.hexdigest(data)
    end
  end
end
