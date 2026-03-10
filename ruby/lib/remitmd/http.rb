# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "securerandom"
require "time"

module Remitmd
  # Chain configuration: maps chain names to (api_url, chain_id) pairs.
  CHAIN_CONFIG = {
    "base"          => { url: "https://api.remit.md/api/v0",          chain_id: 8453 },
    "base_sepolia"  => { url: "https://testnet-api.remit.md/api/v0",  chain_id: 84532 },
    "arbitrum"      => { url: "https://api.remit.md/api/v0",          chain_id: 42161 },
    "optimism"      => { url: "https://api.remit.md/api/v0",          chain_id: 10 },
  }.freeze

  # Default testnet URL for overriding in tests.
  TESTNET_API_URL = ENV.fetch("REMITMD_API_URL", CHAIN_CONFIG["base_sepolia"][:url])

  # HTTP transport layer. Signs each request with EIP-712-style headers and
  # retries transient failures with exponential backoff.
  class HttpTransport
    MAX_RETRIES   = 3
    BASE_DELAY    = 0.5 # seconds
    RETRY_CODES   = [429, 500, 502, 503, 504].freeze

    def initialize(base_url:, signer:, chain_id:)
      @signer   = signer
      @chain_id = chain_id
      @uri      = URI.parse(base_url)
      @http     = build_http(@uri)
    end

    def get(path)
      request(:get, path, nil)
    end

    def post(path, body = nil)
      request(:post, path, body)
    end

    private

    def request(method, path, body)
      attempt = 0
      begin
        attempt += 1
        req = build_request(method, path, body)
        resp = @http.request(req)
        handle_response(resp, path)
      rescue RemitError => e
        raise unless RETRY_CODES.include?(http_status_for(e)) && attempt < MAX_RETRIES

        sleep(BASE_DELAY * (2**(attempt - 1)))
        retry
      rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Net::ReadTimeout => e
        raise RemitError.new(RemitError::NETWORK_ERROR, e.message) if attempt >= MAX_RETRIES

        sleep(BASE_DELAY * (2**(attempt - 1)))
        retry
      end
    end

    def build_request(method, path, body)
      full_path = "#{@uri.path}#{path}"
      req = case method
            when :get  then Net::HTTP::Get.new(full_path)
            when :post then Net::HTTP::Post.new(full_path)
            end

      nonce = SecureRandom.hex(16)
      ts    = Time.now.utc.iso8601
      payload = body ? body.to_json : ""
      signed_data = "#{method.to_s.upcase}\n#{full_path}\n#{nonce}\n#{ts}\n#{payload}"
      signature = @signer.sign(signed_data)

      req["Content-Type"] = "application/json"
      req["X-Remit-Address"]   = @signer.address
      req["X-Remit-Nonce"]     = nonce
      req["X-Remit-Timestamp"] = ts
      req["X-Remit-Signature"] = signature
      req["X-Remit-Chain-Id"]  = @chain_id.to_s

      req.body = payload if body
      req
    end

    def handle_response(resp, path)
      body = resp.body.to_s.strip
      parsed = body.empty? ? {} : JSON.parse(body)

      status = resp.code.to_i
      case status
      when 200..299
        parsed
      when 400
        code = parsed["code"] || RemitError::SERVER_ERROR
        raise RemitError.new(code, parsed["message"] || "Bad request",
                             context: parsed)
      when 401
        raise RemitError.new(RemitError::UNAUTHORIZED,
                             "Authentication failed — check your private key and chain ID")
      when 429
        raise RemitError.new(RemitError::RATE_LIMITED,
                             "Rate limit exceeded. See https://remit.md/docs/api-reference/rate-limits")
      when 404
        raise RemitError.new(RemitError::SERVER_ERROR,
                             "Resource not found: #{path}")
      else
        msg = parsed.is_a?(Hash) ? (parsed["message"] || "Server error") : "Server error (#{status})"
        raise RemitError.new(RemitError::SERVER_ERROR, msg, context: parsed)
      end
    rescue JSON::ParserError
      raise RemitError.new(RemitError::SERVER_ERROR, "Invalid JSON response from API")
    end

    def http_status_for(err)
      case err.code
      when RemitError::RATE_LIMITED then 429
      when RemitError::NETWORK_ERROR then 503
      else 400
      end
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.read_timeout = 15
      http.open_timeout = 5
      http
    end
  end
end
