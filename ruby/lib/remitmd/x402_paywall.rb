# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "base64"

module Remitmd
  # x402 paywall for service providers - gate HTTP endpoints behind payments.
  #
  # Providers use this class to:
  # - Return HTTP 402 responses with properly formatted PAYMENT-REQUIRED headers
  # - Verify incoming PAYMENT-SIGNATURE headers against the remit.md facilitator
  #
  # @example Rack middleware
  #   paywall = Remitmd::X402Paywall.new(
  #     wallet_address: "0xYourProviderWallet",
  #     amount_usdc: 0.001,
  #     network: "eip155:84532",
  #     asset: "0x2d846325766921935f37d5b4478196d3ef93707c"
  #   )
  #   use paywall.rack_middleware
  #
  class X402Paywall
    # @param wallet_address [String] provider's checksummed Ethereum address (the payTo field)
    # @param amount_usdc [Float] price per request in USDC (e.g. 0.001)
    # @param network [String] CAIP-2 network string (e.g. "eip155:84532")
    # @param asset [String] USDC contract address on the target network
    # @param facilitator_url [String] base URL of the remit.md facilitator
    # @param facilitator_token [String] bearer JWT for authenticating calls to /api/v1/x402/verify
    # @param max_timeout_seconds [Integer] how long the payment authorization remains valid
    # @param resource [String, nil] V2 - URL or path of the resource being protected
    # @param description [String, nil] V2 - human-readable description
    # @param mime_type [String, nil] V2 - MIME type of the resource
    def initialize( # rubocop:disable Metrics/ParameterLists
      wallet_address:,
      amount_usdc:,
      network:,
      asset:,
      facilitator_url: "https://remit.md",
      facilitator_token: "",
      max_timeout_seconds: 60,
      resource: nil,
      description: nil,
      mime_type: nil
    )
      @wallet_address      = wallet_address
      @amount_base_units   = (amount_usdc * 1_000_000).round.to_s
      @network             = network
      @asset               = asset
      @facilitator_url     = facilitator_url.chomp("/")
      @facilitator_token   = facilitator_token
      @max_timeout_seconds = max_timeout_seconds
      @resource            = resource
      @description         = description
      @mime_type           = mime_type
    end

    # Return the base64-encoded JSON PAYMENT-REQUIRED header value.
    # @return [String]
    def payment_required_header
      payload = {
        scheme:            "exact",
        network:           @network,
        amount:            @amount_base_units,
        asset:             @asset,
        payTo:             @wallet_address,
        maxTimeoutSeconds: @max_timeout_seconds,
      }
      payload[:resource]    = @resource    if @resource
      payload[:description] = @description if @description
      payload[:mimeType]    = @mime_type   if @mime_type
      Base64.strict_encode64(JSON.generate(payload))
    end

    # Check whether a PAYMENT-SIGNATURE header represents a valid payment.
    # Calls the remit.md facilitator's /api/v1/x402/verify endpoint.
    #
    # @param payment_sig [String, nil] the raw header value (base64 JSON), or nil if absent
    # @return [Hash] { is_valid: true/false, invalid_reason: String or nil }
    def check(payment_sig)
      return { is_valid: false } unless payment_sig

      payment_payload = begin
        JSON.parse(Base64.decode64(payment_sig))
      rescue JSON::ParserError
        return { is_valid: false, invalid_reason: "INVALID_PAYLOAD" }
      end

      body = {
        paymentPayload:  payment_payload,
        paymentRequired: payment_required_object,
      }

      uri = URI("#{@facilitator_url}/api/v1/x402/verify")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.read_timeout = 10

      req = Net::HTTP::Post.new(uri.path)
      req["Content-Type"] = "application/json"
      req["Authorization"] = "Bearer #{@facilitator_token}" unless @facilitator_token.empty?
      req.body = JSON.generate(body)

      begin
        resp = http.request(req)
        unless resp.is_a?(Net::HTTPSuccess)
          return { is_valid: false, invalid_reason: "FACILITATOR_ERROR" }
        end

        data = JSON.parse(resp.body)
      rescue StandardError
        return { is_valid: false, invalid_reason: "FACILITATOR_ERROR" }
      end

      {
        is_valid:       data["isValid"] == true,
        invalid_reason: data["invalidReason"],
      }
    end

    # Rack middleware adapter.
    #
    # @example
    #   use paywall.rack_middleware
    #
    # @return [Class] a Rack middleware class
    def rack_middleware
      paywall = self
      Class.new do
        define_method(:initialize) do |app|
          @app     = app
          @paywall = paywall
        end

        define_method(:call) do |env|
          payment_sig = env["HTTP_PAYMENT_SIGNATURE"]
          result = @paywall.check(payment_sig)

          unless result[:is_valid]
            headers = {
              "Content-Type"     => "application/json",
              "PAYMENT-REQUIRED" => @paywall.payment_required_header,
            }
            body = JSON.generate({
              error:         "Payment required",
              invalidReason: result[:invalid_reason],
            })
            return [402, headers, [body]]
          end

          @app.call(env)
        end
      end
    end

    private

    def payment_required_object
      {
        scheme:            "exact",
        network:           @network,
        amount:            @amount_base_units,
        asset:             @asset,
        payTo:             @wallet_address,
        maxTimeoutSeconds: @max_timeout_seconds,
      }
    end
  end
end
