defmodule RemitMd.Error do
  @moduledoc """
  Error type returned by all remit.md SDK operations.

  Every error has a machine-readable `code`, a human-readable `message`,
  a `doc_url` pointing to the relevant documentation, and optional `context`
  with additional structured data.
  """

  defexception [:code, :message, :doc_url, :context]

  @base_doc "https://remit.md/docs/errors"

  # ─── Error codes (match TS SDK errors.ts — all 28 canonical codes) ────────

  # Auth errors
  @doc "EIP-712 signature verification failed."
  def invalid_signature, do: "INVALID_SIGNATURE"
  @doc "EIP-712 signature verification failed (legacy alias)."
  def signature_invalid, do: "INVALID_SIGNATURE"

  @doc "Nonce has already been used."
  def nonce_reused, do: "NONCE_REUSED"
  @doc "Nonce has already been used (legacy alias)."
  def nonce_replay, do: "NONCE_REUSED"

  @doc "The request timestamp is outside the acceptable window."
  def timestamp_expired, do: "TIMESTAMP_EXPIRED"

  @doc "API key or EIP-712 signature is missing or invalid."
  def unauthorized, do: "UNAUTHORIZED"

  # Balance / funds
  @doc "The invoking agent has insufficient USDC balance."
  def insufficient_balance, do: "INSUFFICIENT_BALANCE"

  @doc "Transaction amount is below minimum."
  def below_minimum, do: "BELOW_MINIMUM"

  # Escrow errors
  @doc "Escrow not found."
  def escrow_not_found, do: "ESCROW_NOT_FOUND"

  @doc "This invoice already has a funded escrow."
  def escrow_already_funded, do: "ESCROW_ALREADY_FUNDED"

  @doc "Escrow has expired."
  def escrow_expired, do: "ESCROW_EXPIRED"

  # Invoice errors
  @doc "Invoice is malformed or invalid."
  def invalid_invoice, do: "INVALID_INVOICE"

  @doc "An invoice with this ID already exists."
  def duplicate_invoice, do: "DUPLICATE_INVOICE"

  @doc "Payer and payee are the same address."
  def self_payment, do: "SELF_PAYMENT"

  @doc "Payment type is not valid for this invoice."
  def invalid_payment_type, do: "INVALID_PAYMENT_TYPE"

  # Tab errors
  @doc "Tab has reached its spending limit."
  def tab_depleted, do: "TAB_DEPLETED"

  @doc "Tab has expired."
  def tab_expired, do: "TAB_EXPIRED"

  @doc "Tab not found."
  def tab_not_found, do: "TAB_NOT_FOUND"

  # Stream errors
  @doc "Stream not found."
  def stream_not_found, do: "STREAM_NOT_FOUND"

  @doc "Streaming rate exceeds the maximum allowed."
  def rate_exceeds_cap, do: "RATE_EXCEEDS_CAP"

  # Bounty errors
  @doc "Bounty has expired."
  def bounty_expired, do: "BOUNTY_EXPIRED"

  @doc "Bounty has already been awarded."
  def bounty_claimed, do: "BOUNTY_CLAIMED"

  @doc "Bounty has reached maximum submission attempts."
  def bounty_max_attempts, do: "BOUNTY_MAX_ATTEMPTS"

  @doc "Bounty not found."
  def bounty_not_found, do: "BOUNTY_NOT_FOUND"

  # Chain errors
  @doc "Invoice chain does not match wallet chain."
  def chain_mismatch, do: "CHAIN_MISMATCH"

  @doc "Chain ID is unsupported or mismatched."
  def chain_unsupported, do: "CHAIN_UNSUPPORTED"

  # Rate limiting
  @doc "Request rate limit exceeded."
  def rate_limited, do: "RATE_LIMITED"

  # Cancellation errors
  @doc "Cannot cancel after claim start."
  def cancel_blocked_claim_start, do: "CANCEL_BLOCKED_CLAIM_START"

  @doc "Cannot cancel while evidence is pending review."
  def cancel_blocked_evidence, do: "CANCEL_BLOCKED_EVIDENCE"

  # Protocol errors
  @doc "SDK version is not compatible with this API version."
  def version_mismatch, do: "VERSION_MISMATCH"

  @doc "A network error occurred connecting to the API."
  def network_error, do: "NETWORK_ERROR"

  # Generic errors (kept for backward compat)
  @doc "Recipient address is invalid or not checksummed."
  def invalid_address, do: "INVALID_ADDRESS"

  @doc "Amount is below the 1 micro-USDC minimum or exceeds the maximum."
  def invalid_amount, do: "INVALID_AMOUNT"

  @doc "The requested resource (escrow, tab, etc.) was not found."
  def not_found, do: "NOT_FOUND"

  @doc "The resource is in the wrong state for this operation."
  def invalid_state, do: "INVALID_STATE"

  @doc "The tab or stream has expired."
  def expired, do: "EXPIRED"

  @doc "The escrow or bounty milestone validation failed."
  def validation_failed, do: "VALIDATION_FAILED"

  @doc "On-chain transaction failed or reverted."
  def transaction_failed, do: "TRANSACTION_FAILED"

  @doc "Spending limit set by the operator has been reached."
  def spending_limit_exceeded, do: "SPENDING_LIMIT_EXCEEDED"

  @doc "The operation is not permitted in the current context."
  def forbidden, do: "FORBIDDEN"

  @doc "Service is temporarily unavailable."
  def service_unavailable, do: "SERVICE_UNAVAILABLE"

  @doc "An unclassified server error occurred."
  def server_error, do: "SERVER_ERROR"

  @doc "Contract call failed (on-chain operation)."
  def contract_error, do: "CONTRACT_ERROR"

  # ─── Error code map (for from_code/2 factory) ───────────────────────────────

  @error_codes %{
    "INVALID_SIGNATURE" => true,
    "NONCE_REUSED" => true,
    "TIMESTAMP_EXPIRED" => true,
    "UNAUTHORIZED" => true,
    "INSUFFICIENT_BALANCE" => true,
    "BELOW_MINIMUM" => true,
    "ESCROW_NOT_FOUND" => true,
    "ESCROW_ALREADY_FUNDED" => true,
    "ESCROW_EXPIRED" => true,
    "INVALID_INVOICE" => true,
    "DUPLICATE_INVOICE" => true,
    "SELF_PAYMENT" => true,
    "INVALID_PAYMENT_TYPE" => true,
    "TAB_DEPLETED" => true,
    "TAB_EXPIRED" => true,
    "TAB_NOT_FOUND" => true,
    "STREAM_NOT_FOUND" => true,
    "RATE_EXCEEDS_CAP" => true,
    "BOUNTY_EXPIRED" => true,
    "BOUNTY_CLAIMED" => true,
    "BOUNTY_MAX_ATTEMPTS" => true,
    "BOUNTY_NOT_FOUND" => true,
    "CHAIN_MISMATCH" => true,
    "CHAIN_UNSUPPORTED" => true,
    "RATE_LIMITED" => true,
    "CANCEL_BLOCKED_CLAIM_START" => true,
    "CANCEL_BLOCKED_EVIDENCE" => true,
    "VERSION_MISMATCH" => true
  }

  @doc "Check if a code string is a known canonical error code."
  def known_code?(code), do: Map.has_key?(@error_codes, code)

  # ─── Constructor helpers ───────────────────────────────────────────────────

  @doc """
  Build a `RemitMd.Error` struct.

      iex> RemitMd.Error.new(RemitMd.Error.not_found(), "Escrow abc123 not found")
      %RemitMd.Error{code: "NOT_FOUND", message: "Escrow abc123 not found", ...}
  """
  def new(code, message, opts \\ []) do
    slug = code |> String.downcase() |> String.replace("_", "-")
    %__MODULE__{
      code: code,
      message: message,
      doc_url: Keyword.get(opts, :doc_url, "#{@base_doc}##{slug}"),
      context: Keyword.get(opts, :context)
    }
  end

  @doc """
  Build a `RemitMd.Error` from an API error code and message string.
  """
  def from_code(code, message \\ nil) do
    msg = message || "Error: #{code}"
    new(code, msg)
  end

  @impl true
  def message(%__MODULE__{code: code, message: msg, doc_url: url}) do
    "[#{code}] #{msg} — #{url}"
  end
end
