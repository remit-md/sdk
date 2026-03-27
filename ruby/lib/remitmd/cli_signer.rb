# frozen_string_literal: true

require "open3"

module Remitmd
  # Signer backed by the `remit sign` CLI command.
  #
  # No key material in this process -- signing happens in a subprocess.
  # Address is cached at construction time via `remit address`.
  #
  # @example
  #   signer = Remitmd::CliSigner.new
  #   wallet = Remitmd::RemitWallet.new(signer: signer, chain: "base")
  #
  class CliSigner
    include Signer

    # Default timeout for CLI subprocess calls (seconds).
    CLI_TIMEOUT = 10

    # Create a CliSigner, fetching and caching the wallet address.
    #
    # @param cli_path [String] path or name of the remit CLI binary (default: "remit")
    # @raise [RemitError] if the CLI fails or returns an invalid address
    def initialize(cli_path: "remit")
      @cli_path = cli_path
      @address = fetch_address
    end

    # Sign a 32-byte digest (raw binary bytes).
    # Pipes the hex-encoded digest to `remit sign --digest` on stdin.
    # Returns a 0x-prefixed 65-byte hex signature.
    #
    # @param digest_bytes [String] 32-byte binary digest
    # @return [String] 0x-prefixed 130-char hex signature (65 bytes)
    # @raise [RemitError] on CLI failure or invalid output
    def sign(digest_bytes)
      hex = digest_bytes.unpack1("H*")
      stdout, stderr, status = run_cli("sign", "--digest", stdin_data: hex)

      unless status.success?
        raise RemitError.new(
          RemitError::SERVER_ERROR,
          "CliSigner: signing failed: #{stderr.strip}"
        )
      end

      sig = stdout.strip
      unless sig.start_with?("0x") && sig.length == 132
        raise RemitError.new(
          RemitError::SERVER_ERROR,
          "CliSigner: invalid signature from CLI: #{sig}"
        )
      end

      sig
    end

    # The cached Ethereum address (0x-prefixed).
    # @return [String]
    attr_reader :address

    # Never expose internals in inspect/to_s output.
    def inspect
      "#<Remitmd::CliSigner address=#{@address}>"
    end

    alias to_s inspect

    # Check all three conditions for CliSigner activation.
    #
    # 1. CLI binary found on PATH (via `which` / `where`)
    # 2. Keystore file exists at ~/.remit/keys/default.enc
    # 3. REMIT_KEY_PASSWORD env var is set
    #
    # @param cli_path [String] path or name of the remit CLI binary
    # @return [Boolean]
    def self.available?(cli_path: "remit")
      # 1. CLI binary on PATH
      which_cmd = Gem.win_platform? ? "where" : "which"
      _out, _err, st = Open3.capture3(which_cmd, cli_path)
      return false unless st.success?

      # 2. Keystore file exists
      keystore = File.join(Dir.home, ".remit", "keys", "default.enc")
      return false unless File.exist?(keystore)

      # 3. REMIT_KEY_PASSWORD set
      password = ENV["REMIT_KEY_PASSWORD"]
      return false if password.nil? || password.empty?

      true
    end

    private

    # Fetch the wallet address from `remit address` during construction.
    # @return [String] the 0x-prefixed Ethereum address
    # @raise [RemitError] on any failure
    def fetch_address
      stdout, stderr, status = run_cli("address")

      unless status.success?
        raise RemitError.new(
          RemitError::SERVER_ERROR,
          "CliSigner: failed to get address: #{stderr.strip}"
        )
      end

      addr = stdout.strip
      unless addr.match?(/\A0x[0-9a-fA-F]{40}\z/)
        raise RemitError.new(
          RemitError::SERVER_ERROR,
          "CliSigner: invalid address from CLI: #{addr}"
        )
      end

      addr
    end

    # Run the remit CLI with given arguments.
    # @param args [Array<String>] CLI arguments
    # @param stdin_data [String, nil] data to pipe to stdin
    # @return [Array<String, String, Process::Status>] stdout, stderr, status
    # @raise [RemitError] on timeout or execution failure
    def run_cli(*args, stdin_data: nil)
      Open3.capture3(@cli_path, *args, stdin_data: stdin_data.to_s)
    rescue Errno::ENOENT
      raise RemitError.new(
        RemitError::SERVER_ERROR,
        "CliSigner: remit CLI not found at '#{@cli_path}'. " \
        "Install: https://remit.md/install"
      )
    end
  end
end
