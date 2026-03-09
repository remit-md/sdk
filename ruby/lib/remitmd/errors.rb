# frozen_string_literal: true

module Remitmd
  # Structured error raised by all remit.md SDK operations.
  #
  # Every error has a machine-readable code, a human-readable message with
  # actionable context, and a doc_url pointing to the specific error documentation.
  #
  # @example
  #   begin
  #     wallet.pay("not-an-address", 1.00)
  #   rescue Remitmd::RemitError => e
  #     puts e.code     # => "INVALID_ADDRESS"
  #     puts e.message  # => "[INVALID_ADDRESS] expected 0x-prefixed ..."
  #     puts e.doc_url  # => "https://remit.md/docs/api-reference/error-codes#invalid_address"
  #   end
  class RemitError < StandardError
    # Error code constants
    INVALID_ADDRESS         = "INVALID_ADDRESS"
    INVALID_AMOUNT          = "INVALID_AMOUNT"
    INSUFFICIENT_FUNDS      = "INSUFFICIENT_FUNDS"
    ESCROW_NOT_FOUND        = "ESCROW_NOT_FOUND"
    TAB_NOT_FOUND           = "TAB_NOT_FOUND"
    STREAM_NOT_FOUND        = "STREAM_NOT_FOUND"
    BOUNTY_NOT_FOUND        = "BOUNTY_NOT_FOUND"
    DEPOSIT_NOT_FOUND       = "DEPOSIT_NOT_FOUND"
    UNAUTHORIZED            = "UNAUTHORIZED"
    RATE_LIMITED            = "RATE_LIMITED"
    NETWORK_ERROR           = "NETWORK_ERROR"
    SERVER_ERROR            = "SERVER_ERROR"
    NONCE_REUSED            = "NONCE_REUSED"
    SIGNATURE_INVALID       = "SIGNATURE_INVALID"
    ESCROW_ALREADY_RELEASED = "ESCROW_ALREADY_RELEASED"
    ESCROW_EXPIRED          = "ESCROW_EXPIRED"
    TAB_LIMIT_EXCEEDED      = "TAB_LIMIT_EXCEEDED"
    BOUNTY_ALREADY_AWARDED  = "BOUNTY_ALREADY_AWARDED"
    STREAM_NOT_ACTIVE       = "STREAM_NOT_ACTIVE"
    DEPOSIT_ALREADY_SETTLED = "DEPOSIT_ALREADY_SETTLED"
    USDC_TRANSFER_FAILED    = "USDC_TRANSFER_FAILED"
    CHAIN_UNAVAILABLE       = "CHAIN_UNAVAILABLE"

    attr_reader :code, :doc_url, :context

    def initialize(code, message, context: {})
      @code    = code
      @doc_url = "https://remit.md/docs/api-reference/error-codes##{code.downcase}"
      @context = context
      super("[#{code}] #{message} — #{@doc_url}")
    end
  end
end
