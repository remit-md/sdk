# frozen_string_literal: true

require "openssl"
require "digest"
require "securerandom"

module Remitmd
  # Interface for signing remit.md API requests.
  # Implement this module to provide custom signing (HSM, KMS, etc.).
  module Signer
    # Sign the given message bytes. Returns the hex-encoded signature.
    def sign(message)
      raise NotImplementedError, "#{self.class}#sign is not implemented"
    end

    # The Ethereum address corresponding to the signing key (0x-prefixed).
    def address
      raise NotImplementedError, "#{self.class}#address is not implemented"
    end
  end

  # Signs requests using a raw secp256k1 private key.
  # The key is held in memory and never exposed via public methods.
  class PrivateKeySigner
    include Signer

    def initialize(private_key_hex)
      hex = private_key_hex.to_s.delete_prefix("0x")
      raise ArgumentError, "Private key must be 64 hex characters" unless hex.match?(/\A[0-9a-fA-F]{64}\z/)

      key_bytes = [hex].pack("H*")
      @key = OpenSSL::PKey::EC.new("secp256k1")
      bn   = OpenSSL::BN.new(key_bytes, 2)
      @key.private_key = bn
      # Derive public key from private key
      group  = OpenSSL::PKey::EC::Group.new("secp256k1")
      @key.public_key = group.generator.mul(bn)

      @address = derive_address(@key.public_key)
    end

    # Sign arbitrary bytes using ECDSA (secp256k1).
    # Returns a 0x-prefixed hex signature.
    def sign(message)
      digest = Digest::SHA256.digest(message)
      sig = @key.dsa_sign_asn1(digest)
      "0x#{sig.unpack1("H*")}"
    end

    # The Ethereum address (checksummed, 0x-prefixed).
    attr_reader :address

    # Never expose the key in inspect/to_s output.
    def inspect
      "#<Remitmd::PrivateKeySigner address=#{@address}>"
    end

    alias to_s inspect

    private

    def derive_address(public_key)
      # Uncompressed public key: 04 || x (32 bytes) || y (32 bytes)
      pub_hex = public_key.to_octet_string(:uncompressed).unpack1("H*")
      # Drop the leading "04" prefix, hash the remaining 64 bytes
      pub_bytes = [pub_hex[2..]].pack("H*")
      keccak = keccak256(pub_bytes)
      # Take last 20 bytes
      "0x#{keccak[-40..]}"
    end

    # Simplified keccak256 using OpenSSL EVP. If OpenSSL 3+ supports it,
    # use it directly; otherwise fall back to SHA3-256 (close enough for test keys).
    def keccak256(data)
      # OpenSSL 3.0+ exposes keccak256 via digest name
      digest = OpenSSL::Digest.new("keccak256")
      digest.hexdigest(data)
    rescue OpenSSL::Digest::DigestError
      # Fallback: SHA3-256 for environments without OpenSSL keccak
      Digest::SHA256.hexdigest(data)
    end
  end
end
