# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "securerandom"
require "openssl"

module Remitmd
  # Chain configuration: maps chain names to (api_url, chain_id) pairs.
  CHAIN_CONFIG = {
    "base"          => { url: "https://api.remit.md/api/v0",          chain_id: 8453 },
    "base_sepolia"  => { url: "https://testnet.remit.md/api/v0",      chain_id: 84532 },
    "arbitrum"      => { url: "https://arb.remit.md/api/v0",          chain_id: 42161 },
    "optimism"      => { url: "https://op.remit.md/api/v0",           chain_id: 10 },
  }.freeze

  # HTTP transport layer. Signs each request with EIP-712 auth headers and
  # retries transient failures with exponential backoff.
  class HttpTransport
    MAX_RETRIES = 3
    BASE_DELAY  = 0.5 # seconds
    RETRY_CODES = [429, 500, 502, 503, 504].freeze

    def initialize(base_url:, signer:, chain_id:, router_address: "")
      @signer         = signer
      @chain_id       = chain_id
      @router_address = router_address.to_s
      @uri            = URI.parse(base_url)
      @http           = build_http(@uri)
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
        req  = build_request(method, path, body)
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

      # Generate 32-byte random nonce and Unix timestamp.
      nonce_bytes = SecureRandom.bytes(32)
      nonce_hex   = "0x#{nonce_bytes.unpack1("H*")}"
      timestamp   = Time.now.to_i

      # Compute EIP-712 hash and sign it.
      http_method = method.to_s.upcase
      digest      = eip712_hash(http_method, full_path, timestamp, nonce_bytes)
      signature   = @signer.sign(digest)

      req["Content-Type"]      = "application/json"
      req["Accept"]            = "application/json"
      req["X-Remit-Agent"]     = @signer.address
      req["X-Remit-Nonce"]     = nonce_hex
      req["X-Remit-Timestamp"] = timestamp.to_s
      req["X-Remit-Signature"] = signature

      if body
        req.body = body.to_json
      end
      req
    end

    # ─── EIP-712 ──────────────────────────────────────────────────────────────

    # Computes the EIP-712 hash for an APIRequest struct.
    # Domain: name="remit.md", version="0.1", chainId, verifyingContract
    # Struct: APIRequest(string method, string path, uint256 timestamp, bytes32 nonce)
    def eip712_hash(method, path, timestamp, nonce_bytes)
      # Type hashes (string constants — keccak256 of the type string)
      domain_type_hash  = keccak256_bytes(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
      )
      request_type_hash = keccak256_bytes(
        "APIRequest(string method,string path,uint256 timestamp,bytes32 nonce)"
      )

      # Domain separator
      name_hash     = keccak256_bytes("remit.md")
      version_hash  = keccak256_bytes("0.1")
      chain_id_enc  = abi_uint256(@chain_id)
      contract_enc  = abi_address(@router_address)

      domain_data      = domain_type_hash + name_hash + version_hash + chain_id_enc + contract_enc
      domain_separator = keccak256_bytes(domain_data)

      # Struct hash
      method_hash    = keccak256_bytes(method)
      path_hash      = keccak256_bytes(path)
      timestamp_enc  = abi_uint256(timestamp)

      struct_data = request_type_hash + method_hash + path_hash + timestamp_enc + nonce_bytes
      struct_hash = keccak256_bytes(struct_data)

      # Final hash: "\x19\x01" || domainSeparator || structHash
      keccak256_bytes("\x19\x01" + domain_separator + struct_hash)
    end

    # Encode an integer as a 32-byte big-endian ABI uint256.
    def abi_uint256(value)
      [value.to_i.to_s(16).rjust(64, "0")].pack("H*")
    end

    # Encode a 20-byte Ethereum address as a 32-byte ABI word (left-zero-padded).
    def abi_address(addr)
      hex = addr.to_s.delete_prefix("0x").rjust(64, "0")
      [hex].pack("H*")
    end

    # Returns the keccak256 digest as raw binary bytes.
    def keccak256_bytes(data)
      Remitmd::Keccak.digest(data)
    end

    # ─── Response handling ────────────────────────────────────────────────────

    def handle_response(resp, path)
      body   = resp.body.to_s.strip
      parsed = body.empty? ? {} : JSON.parse(body)

      status = resp.code.to_i
      case status
      when 200..299
        parsed
      when 400
        code = parsed["code"] || RemitError::SERVER_ERROR
        raise RemitError.new(code, parsed["message"] || "Bad request", context: parsed)
      when 401
        raise RemitError.new(RemitError::UNAUTHORIZED,
                             "Authentication failed — check your private key and chain ID")
      when 429
        raise RemitError.new(RemitError::RATE_LIMITED,
                             "Rate limit exceeded. See https://remit.md/docs/api-reference/rate-limits")
      when 404
        raise RemitError.new(RemitError::SERVER_ERROR, "Resource not found: #{path}")
      else
        msg = parsed.is_a?(Hash) ? (parsed["message"] || "Server error") : "Server error (#{status})"
        raise RemitError.new(RemitError::SERVER_ERROR, msg, context: parsed)
      end
    rescue JSON::ParserError
      raise RemitError.new(RemitError::SERVER_ERROR, "Invalid JSON response from API")
    end

    def http_status_for(err)
      case err.code
      when RemitError::RATE_LIMITED   then 429
      when RemitError::NETWORK_ERROR  then 503
      else 400
      end
    end

    def build_http(uri)
      http             = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl     = uri.scheme == "https"
      http.read_timeout = 15
      http.open_timeout = 5
      http
    end
  end
end
