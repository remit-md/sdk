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
        "x402 payment #{format("%.6f", amount_usdc)} USDC exceeds auto-pay limit #{format("%.6f", limit_usdc)} USDC"
      )
    end
  end

  # x402 client - fetch wrapper that auto-pays HTTP 402 Payment Required responses.
  #
  # On receiving a 402, the client:
  # 1. Decodes the PAYMENT-REQUIRED header (base64 JSON)
  # 2. Checks the amount is within max_auto_pay_usdc
  # 3. Calls /x402/prepare to get hash + authorization fields
  # 4. Signs the hash
  # 5. Base64-encodes the PAYMENT-SIGNATURE header
  # 6. Retries the original request with payment attached
  #
  # @example
  #   signer = Remitmd::PrivateKeySigner.new("0x...")
  #   client = Remitmd::X402Client.new(wallet: signer, api_transport: transport)
  #   response = client.fetch("https://api.provider.com/v1/data")
  #
  class X402Client
    attr_reader :last_payment

    # @param wallet [#sign_hash, #address] a signer that can sign raw hashes
    # @param api_transport [#post] authenticated HTTP transport for calling /x402/prepare
    # @param max_auto_pay_usdc [Float] maximum USDC amount to auto-pay per request (default: 0.10)
    def initialize(wallet:, api_transport: nil, max_auto_pay_usdc: 0.10)
      @wallet            = wallet
      @api_transport     = api_transport
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
        handle402(uri, resp, method, headers, body)
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

    def handle402(uri, response, method, headers, body)
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

      # 4. Call /x402/prepare to get the hash + authorization fields.
      unless @api_transport
        raise RemitError.new("SERVER_ERROR",
          "x402 auto-pay requires an api_transport for calling /x402/prepare")
      end

      prepare_data = @api_transport.post("/x402/prepare", {
        payment_required: raw,
        payer: @wallet.address
      })

      # 5. Sign the hash.
      hash_hex = prepare_data["hash"]
      hash_bytes = [hash_hex.delete_prefix("0x")].pack("H*")
      signature = @wallet.sign_hash(hash_bytes)

      # 6. Build PAYMENT-SIGNATURE JSON payload.
      payment_payload = {
        scheme:      required["scheme"],
        network:     required["network"],
        x402Version: 1,
        payload: {
          signature: signature,
          authorization: {
            from:        prepare_data["from"],
            to:          prepare_data["to"],
            value:       prepare_data["value"],
            validAfter:  prepare_data["valid_after"] || prepare_data["validAfter"],
            validBefore: prepare_data["valid_before"] || prepare_data["validBefore"],
            nonce:       prepare_data["nonce"],
          },
        },
      }
      payment_header = Base64.strict_encode64(JSON.generate(payment_payload))

      # 7. Retry with PAYMENT-SIGNATURE header.
      new_headers = headers.merge("PAYMENT-SIGNATURE" => payment_header)
      make_request(uri, method, new_headers, body)
    end
  end
end
