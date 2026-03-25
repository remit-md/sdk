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
    # Error code constants — matches TS SDK (28 codes)
    # Auth errors
    INVALID_SIGNATURE       = "INVALID_SIGNATURE"
    NONCE_REUSED            = "NONCE_REUSED"
    TIMESTAMP_EXPIRED       = "TIMESTAMP_EXPIRED"
    UNAUTHORIZED            = "UNAUTHORIZED"

    # Balance / funds
    INSUFFICIENT_BALANCE    = "INSUFFICIENT_BALANCE"
    BELOW_MINIMUM           = "BELOW_MINIMUM"

    # Escrow errors
    ESCROW_NOT_FOUND        = "ESCROW_NOT_FOUND"
    ESCROW_ALREADY_FUNDED   = "ESCROW_ALREADY_FUNDED"
    ESCROW_EXPIRED          = "ESCROW_EXPIRED"

    # Invoice errors
    INVALID_INVOICE         = "INVALID_INVOICE"
    DUPLICATE_INVOICE       = "DUPLICATE_INVOICE"
    SELF_PAYMENT            = "SELF_PAYMENT"
    INVALID_PAYMENT_TYPE    = "INVALID_PAYMENT_TYPE"

    # Tab errors
    TAB_DEPLETED            = "TAB_DEPLETED"
    TAB_EXPIRED             = "TAB_EXPIRED"
    TAB_NOT_FOUND           = "TAB_NOT_FOUND"

    # Stream errors
    STREAM_NOT_FOUND        = "STREAM_NOT_FOUND"
    RATE_EXCEEDS_CAP        = "RATE_EXCEEDS_CAP"

    # Bounty errors
    BOUNTY_EXPIRED          = "BOUNTY_EXPIRED"
    BOUNTY_CLAIMED          = "BOUNTY_CLAIMED"
    BOUNTY_MAX_ATTEMPTS     = "BOUNTY_MAX_ATTEMPTS"
    BOUNTY_NOT_FOUND        = "BOUNTY_NOT_FOUND"

    # Chain errors
    CHAIN_MISMATCH          = "CHAIN_MISMATCH"
    CHAIN_UNSUPPORTED       = "CHAIN_UNSUPPORTED"

    # Rate limiting
    RATE_LIMITED             = "RATE_LIMITED"

    # Cancellation errors
    CANCEL_BLOCKED_CLAIM_START = "CANCEL_BLOCKED_CLAIM_START"
    CANCEL_BLOCKED_EVIDENCE    = "CANCEL_BLOCKED_EVIDENCE"

    # Protocol errors
    VERSION_MISMATCH        = "VERSION_MISMATCH"
    NETWORK_ERROR           = "NETWORK_ERROR"

    # Legacy aliases (kept for backward compat within the SDK)
    INVALID_ADDRESS         = "INVALID_ADDRESS"
    INVALID_AMOUNT          = "INVALID_AMOUNT"
    INSUFFICIENT_FUNDS      = INSUFFICIENT_BALANCE
    SERVER_ERROR            = "SERVER_ERROR"
    DEPOSIT_NOT_FOUND       = "DEPOSIT_NOT_FOUND"

    attr_reader :code, :doc_url, :context

    def initialize(code, message, context: {})
      @code    = code
      @doc_url = "https://remit.md/docs/api-reference/error-codes##{code.downcase}"
      @context = context
      super("[#{code}] #{message} — #{@doc_url}")
    end
  end
end
