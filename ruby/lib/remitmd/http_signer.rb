# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Remitmd
  # Signer backed by a local HTTP signing server.
  #
  # Delegates digest signing to an HTTP server (typically
  # `http://127.0.0.1:7402`). The signer server holds the encrypted key;
  # this adapter only needs a bearer token and URL.
  #
  # @example
  #   signer = Remitmd::HttpSigner.new(url: "http://127.0.0.1:7402", token: "rmit_sk_...")
  #   wallet = Remitmd::RemitWallet.new(signer: signer, chain: "base")
  #
  class HttpSigner
    include Signer

    # Create an HttpSigner, fetching and caching the wallet address.
    #
    # @param url [String] signer server URL (e.g. "http://127.0.0.1:7402")
    # @param token [String] bearer token for authentication
    # @raise [RemitError] if the server is unreachable, returns an error, or returns no address
    def initialize(url:, token:)
      @url = url.chomp("/")
      @token = token
      @address = fetch_address
    end

    # Sign a 32-byte digest (raw binary bytes).
    # Posts to /sign/digest with the hex-encoded digest.
    # Returns a 0x-prefixed 65-byte hex signature.
    #
    # @param digest_bytes [String] 32-byte binary digest
    # @return [String] 0x-prefixed 65-byte hex signature
    # @raise [RemitError] on network, auth, policy, or server errors
    def sign(digest_bytes)
      hex = "0x#{digest_bytes.unpack1("H*")}"
      uri = URI("#{@url}/sign/digest")
      http = build_http(uri)

      req = Net::HTTP::Post.new(uri.path)
      req["Content-Type"] = "application/json"
      req["Authorization"] = "Bearer #{@token}"
      req.body = { digest: hex }.to_json

      resp = begin
        http.request(req)
      rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, SocketError => e
        raise RemitError.new(
          RemitError::NETWORK_ERROR,
          "HttpSigner: cannot reach signer server at #{@url}: #{e.message}"
        )
      end

      handle_sign_response(resp)
    end

    # The cached Ethereum address (0x-prefixed).
    # @return [String]
    attr_reader :address

    # Never expose the bearer token in inspect/to_s output.
    def inspect
      "#<Remitmd::HttpSigner address=#{@address}>"
    end

    alias to_s inspect

    private

    # Fetch the wallet address from GET /address during construction.
    # @return [String] the 0x-prefixed Ethereum address
    # @raise [RemitError] on any failure
    def fetch_address
      uri = URI("#{@url}/address")
      http = build_http(uri)

      req = Net::HTTP::Get.new(uri.path)
      req["Authorization"] = "Bearer #{@token}"

      resp = begin
        http.request(req)
      rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, SocketError => e
        raise RemitError.new(
          RemitError::NETWORK_ERROR,
          "HttpSigner: cannot reach signer server at #{@url}: #{e.message}"
        )
      end

      status = resp.code.to_i

      if status == 401
        raise RemitError.new(
          RemitError::UNAUTHORIZED,
          "HttpSigner: unauthorized -- check your REMIT_SIGNER_TOKEN"
        )
      end

      unless (200..299).cover?(status)
        raise RemitError.new(
          RemitError::SERVER_ERROR,
          "HttpSigner: GET /address failed (#{status})"
        )
      end

      body = begin
        JSON.parse(resp.body.to_s)
      rescue JSON::ParserError
        raise RemitError.new(
          RemitError::SERVER_ERROR,
          "HttpSigner: GET /address returned malformed JSON"
        )
      end

      addr = body["address"]
      if addr.nil? || addr.to_s.empty?
        raise RemitError.new(
          RemitError::SERVER_ERROR,
          "HttpSigner: GET /address returned no address"
        )
      end

      addr.to_s
    end

    # Handle the response from POST /sign/digest.
    # @param resp [Net::HTTPResponse]
    # @return [String] the 0x-prefixed hex signature
    # @raise [RemitError] on any error
    def handle_sign_response(resp)
      status = resp.code.to_i

      if status == 401
        raise RemitError.new(
          RemitError::UNAUTHORIZED,
          "HttpSigner: unauthorized -- check your REMIT_SIGNER_TOKEN"
        )
      end

      if status == 403
        reason = begin
          data = JSON.parse(resp.body.to_s)
          data["reason"] || "unknown"
        rescue JSON::ParserError
          "unknown"
        end
        raise RemitError.new(
          RemitError::UNAUTHORIZED,
          "HttpSigner: policy denied -- #{reason}"
        )
      end

      unless (200..299).cover?(status)
        detail = begin
          data = JSON.parse(resp.body.to_s)
          data["reason"] || data["error"] || "server error"
        rescue JSON::ParserError
          "server error"
        end
        raise RemitError.new(
          RemitError::SERVER_ERROR,
          "HttpSigner: sign failed (#{status}): #{detail}"
        )
      end

      body = begin
        JSON.parse(resp.body.to_s)
      rescue JSON::ParserError
        raise RemitError.new(
          RemitError::SERVER_ERROR,
          "HttpSigner: POST /sign/digest returned malformed JSON"
        )
      end

      sig = body["signature"]
      if sig.nil? || sig.to_s.empty?
        raise RemitError.new(
          RemitError::SERVER_ERROR,
          "HttpSigner: server returned no signature"
        )
      end

      sig.to_s
    end

    # Build a Net::HTTP client for the given URI.
    # @param uri [URI] the target URI
    # @return [Net::HTTP]
    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 10
      http
    end
  end
end
