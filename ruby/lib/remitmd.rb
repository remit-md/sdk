# frozen_string_literal: true

require_relative "remitmd/errors"
require_relative "remitmd/models"
require_relative "remitmd/keccak"
require_relative "remitmd/signer"
require_relative "remitmd/cli_signer"
require_relative "remitmd/http"
require_relative "remitmd/wallet"
require_relative "remitmd/mock"
require_relative "remitmd/a2a"
require_relative "remitmd/x402_client"
require_relative "remitmd/x402_paywall"

# remit.md Ruby SDK - universal payment protocol for AI agents.
#
# @example Direct payment
#   wallet = Remitmd::RemitWallet.new(private_key: ENV["REMITMD_PRIVATE_KEY"])
#   tx = wallet.pay("0xRecipient0000000000000000000000000000001", 1.50)
#   puts tx.tx_hash
#
# @example Using MockRemit in tests
#   mock   = Remitmd::MockRemit.new
#   wallet = mock.wallet
#   wallet.pay("0x0000000000000000000000000000000000000001", 1.00)
#   mock.was_paid?("0x0000000000000000000000000000000000000001", 1.00) # => true
#
module Remitmd
  VERSION = "0.3.0"
end
