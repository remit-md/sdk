defmodule RemitMd.Error do
  @moduledoc """
  Error type returned by all remit.md SDK operations.

  Every error has a machine-readable `code`, a human-readable `message`,
  a `doc_url` pointing to the relevant documentation, and optional `context`
  with additional structured data.
  """

  defexception [:code, :message, :doc_url, :context]

  @base_doc "https://remit.md/docs/errors"

  # ─── Error codes (match shared/errors.ts) ────────────────────────────────

  @doc "Recipient address is invalid or not checksummed."
  def invalid_address, do: "INVALID_ADDRESS"

  @doc "Amount is below the 1 micro-USDC minimum or exceeds the maximum."
  def invalid_amount, do: "INVALID_AMOUNT"

  @doc "The invoking agent has insufficient USDC balance."
  def insufficient_balance, do: "INSUFFICIENT_BALANCE"

  @doc "API key or EIP-712 signature is missing or invalid."
  def unauthorized, do: "UNAUTHORIZED"

  @doc "Request rate limit exceeded."
  def rate_limited, do: "RATE_LIMITED"

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

  @doc "EIP-712 signature verification failed."
  def signature_invalid, do: "SIGNATURE_INVALID"

  @doc "The request timestamp is outside the acceptable window."
  def timestamp_expired, do: "TIMESTAMP_EXPIRED"

  @doc "Nonce has already been used."
  def nonce_replay, do: "NONCE_REPLAY"

  @doc "Spending limit set by the operator has been reached."
  def spending_limit_exceeded, do: "SPENDING_LIMIT_EXCEEDED"

  @doc "The operation is not permitted in the current context."
  def forbidden, do: "FORBIDDEN"

  @doc "Chain ID is unsupported or mismatched."
  def chain_unsupported, do: "CHAIN_UNSUPPORTED"

  @doc "Service is temporarily unavailable."
  def service_unavailable, do: "SERVICE_UNAVAILABLE"

  @doc "A network error occurred connecting to the API."
  def network_error, do: "NETWORK_ERROR"

  @doc "An unclassified server error occurred."
  def server_error, do: "SERVER_ERROR"

  @doc "Contract call failed (on-chain operation)."
  def contract_error, do: "CONTRACT_ERROR"

  @doc "Payer and payee are the same address."
  def self_payment, do: "SELF_PAYMENT"

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

  @impl true
  def message(%__MODULE__{code: code, message: msg, doc_url: url}) do
    "[#{code}] #{msg} — #{url}"
  end
end
