# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "securerandom"
require "base64"

module Remitmd
  # Raised when an x402 payment amount exceeds the configured auto-pay limit.
  class AllowanceExceededError < RemitError
    attr_reader :amount_usdc, :limit_usdc

    def initialize(amount_usdc, limit_usdc)
      @amount_usdc = amount_usdc
      @limit_usdc  = limit_usdc
      super(
        "ALLOWANCE_EXCEEDED",
        "x402 payment #{"%.6f" % amount_usdc} USDC exceeds auto-pay limit #{"%.6f" % limit_usdc} USDC"
      )
    end
  end

  # x402 client — fetch wrapper that auto-pays HTTP 402 Payment Required responses.
  #
  # On receiving a 402, the client:
  # 1. Decodes the PAYMENT-REQUIRED header (base64 JSON)
  # 2. Checks the amount is within max_auto_pay_usdc
  # 3. Builds and signs an EIP-3009 transferWithAuthorization
  # 4. Base64-encodes the PAYMENT-SIGNATURE header
  # 5. Retries the original request with payment attached
  #
  # @example
  #   signer = Remitmd::PrivateKeySigner.new("0x...")
  #   client = Remitmd::X402Client.new(wallet: signer)
  #   response = client.fetch("https://api.provider.com/v1/data")
  #
  class X402Client
    attr_reader :last_payment

    # @param wallet [#sign, #address] a signer that can sign EIP-712 digests
    # @param max_auto_pay_usdc [Float] maximum USDC amount to auto-pay per request (default: 0.10)
    def initialize(wallet:, max_auto_pay_usdc: 0.10)
      @wallet            = wallet
      @max_auto_pay_usdc = max_auto_pay_usdc
      @last_payment      = nil
    end

    # Make an HTTP request, auto-paying any 402 responses within the configured limit.
    #
    # @param url [String] the URL to fetch
    # @param method [Symbol] HTTP method (:get, :post, etc.)
    # @param headers [Hash] additional request headers
    # @param body [String, nil] request body (for POST/PUT)
    # @return [Net::HTTPResponse]
    def fetch(url, method: :get, headers: {}, body: nil)
      uri  = URI(url)
      resp = make_request(uri, method, headers, body)

      if resp.code.to_i == 402
        handle_402(uri, resp, method, headers, body)
      else
        resp
      end
    end

    private

    def make_request(uri, method, headers, body)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.read_timeout = 15

      req = case method
            when :get    then Net::HTTP::Get.new(uri)
            when :post   then Net::HTTP::Post.new(uri)
            when :put    then Net::HTTP::Put.new(uri)
            when :delete then Net::HTTP::Delete.new(uri)
            else              Net::HTTP::Get.new(uri)
            end

      headers.each { |k, v| req[k.to_s] = v.to_s }
      req.body = body if body
      http.request(req)
    end

    def handle_402(uri, response, method, headers, body)
      # 1. Decode PAYMENT-REQUIRED header.
      raw = response["payment-required"] || response["PAYMENT-REQUIRED"]
      raise RemitError.new("SERVER_ERROR", "402 response missing PAYMENT-REQUIRED header") unless raw

      required = JSON.parse(Base64.decode64(raw))

      # 2. Only "exact" scheme is supported.
      unless required["scheme"] == "exact"
        raise RemitError.new("SERVER_ERROR", "Unsupported x402 scheme: #{required["scheme"]}")
      end

      # Store for caller inspection (V2 fields: resource, description, mimeType).
      @last_payment = required

      # 3. Check auto-pay limit.
      amount_base_units = required["amount"].to_i
      amount_usdc       = amount_base_units / 1_000_000.0
      if amount_usdc > @max_auto_pay_usdc
        raise AllowanceExceededError.new(amount_usdc, @max_auto_pay_usdc)
      end

      # 4. Parse chainId from CAIP-2 network string (e.g. "eip155:84532" -> 84532).
      chain_id = required["network"].split(":")[1].to_i

      # 5. Build EIP-3009 authorization fields.
      now_secs     = Time.now.to_i
      valid_before = now_secs + (required["maxTimeoutSeconds"] || 60).to_i
      nonce_bytes  = SecureRandom.bytes(32)
      nonce_hex    = "0x#{nonce_bytes.unpack1("H*")}"

      # 6. Sign EIP-712 typed data for TransferWithAuthorization.
      digest = eip3009_digest(
        chain_id:     chain_id,
        asset:        required["asset"],
        from:         @wallet.address,
        to:           required["payTo"],
        value:        amount_base_units,
        valid_after:  0,
        valid_before: valid_before,
        nonce_bytes:  nonce_bytes
      )
      signature = @wallet.sign(digest)

      # 7. Build PAYMENT-SIGNATURE JSON payload.
      payment_payload = {
        scheme:      required["scheme"],
        network:     required["network"],
        x402Version: 1,
        payload: {
          signature:     signature,
          authorization: {
            from:        @wallet.address,
            to:          required["payTo"],
            value:       required["amount"],
            validAfter:  "0",
            validBefore: valid_before.to_s,
            nonce:       nonce_hex,
          },
        },
      }
      payment_header = Base64.strict_encode64(JSON.generate(payment_payload))

      # 8. Retry with PAYMENT-SIGNATURE header.
      new_headers = headers.merge("PAYMENT-SIGNATURE" => payment_header)
      make_request(uri, method, new_headers, body)
    end

    # Compute the EIP-712 hash for EIP-3009 TransferWithAuthorization.
    def eip3009_digest(chain_id:, asset:, from:, to:, value:, valid_after:, valid_before:, nonce_bytes:)
      # Domain separator: USD Coin / version 2
      domain_type_hash = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
      )
      name_hash     = keccak256("USD Coin")
      version_hash  = keccak256("2")
      chain_id_enc  = abi_uint256(chain_id)
      contract_enc  = abi_address(asset)

      domain_data      = domain_type_hash + name_hash + version_hash + chain_id_enc + contract_enc
      domain_separator = keccak256(domain_data)

      # TransferWithAuthorization struct hash
      type_hash = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
      )
      struct_data = type_hash +
                    abi_address(from) +
                    abi_address(to) +
                    abi_uint256(value) +
                    abi_uint256(valid_after) +
                    abi_uint256(valid_before) +
                    nonce_bytes

      struct_hash = keccak256(struct_data)

      # Final EIP-712 hash
      keccak256("\x19\x01" + domain_separator + struct_hash)
    end

    def keccak256(data)
      Remitmd::Keccak.digest(data.b)
    end

    def abi_uint256(value)
      [value.to_i.to_s(16).rjust(64, "0")].pack("H*")
    end

    def abi_address(addr)
      hex = addr.to_s.delete_prefix("0x").rjust(64, "0")
      [hex].pack("H*")
    end
  end
end
