# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Remitmd
  # A2A capability extension declared in an agent card.
  AgentExtension = Data.define(:uri, :description, :required)

  # A single skill declared in an A2A agent card.
  AgentSkill = Data.define(:id, :name, :description, :tags)

  # A2A agent card parsed from +/.well-known/agent-card.json+.
  class AgentCard
    attr_reader :protocol_version, :name, :description, :url, :version,
                :documentation_url, :capabilities, :skills, :x402

    def initialize(data)
      @protocol_version = data["protocolVersion"] || "0.6"
      @name             = data["name"].to_s
      @description      = data["description"].to_s
      @url              = data["url"].to_s
      @version          = data["version"].to_s
      @documentation_url = data["documentationUrl"].to_s
      @capabilities     = data["capabilities"] || {}
      @skills           = (data["skills"] || []).map do |s|
        AgentSkill.new(
          id:          s["id"].to_s,
          name:        s["name"].to_s,
          description: s["description"].to_s,
          tags:        s["tags"] || []
        )
      end
      @x402 = data["x402"] || {}
    end

    # Fetch and parse the A2A agent card from +base_url/.well-known/agent-card.json+.
    #
    #   card = Remitmd::AgentCard.discover("https://remit.md")
    #   puts card.name   # => "remit.md"
    #   puts card.url    # => "https://remit.md/a2a"
    #
    # @param base_url [String] root URL of the agent
    # @return [AgentCard]
    def self.discover(base_url)
      url = URI("#{base_url.chomp("/")}/.well-known/agent-card.json")
      response = Net::HTTP.start(url.host, url.port, use_ssl: url.scheme == "https") do |http|
        req = Net::HTTP::Get.new(url)
        req["Accept"] = "application/json"
        http.request(req)
      end
      raise "Agent card discovery failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      new(JSON.parse(response.body))
    end
  end

  # ─── A2A task types ──────────────────────────────────────────────────────────

  # Status of an A2A task.
  class A2ATaskStatus
    attr_reader :state, :message

    def initialize(data)
      @state   = data["state"].to_s
      @message = data["message"]
    end
  end

  # An artifact part within an A2A artifact.
  A2AArtifactPart = Data.define(:kind, :data)

  # An artifact returned by an A2A task.
  class A2AArtifact
    attr_reader :name, :parts

    def initialize(data)
      @name  = data["name"]
      @parts = (data["parts"] || []).map do |p|
        A2AArtifactPart.new(kind: p["kind"].to_s, data: p["data"] || {})
      end
    end
  end

  # An A2A task returned by message/send, tasks/get, or tasks/cancel.
  class A2ATask
    attr_reader :id, :status, :artifacts

    def initialize(data)
      @id        = data["id"].to_s
      @status    = A2ATaskStatus.new(data["status"] || {})
      @artifacts = (data["artifacts"] || []).map { |a| A2AArtifact.new(a) }
    end

    # Extract txHash from task artifacts, if present.
    # @return [String, nil]
    def tx_hash
      artifacts.each do |artifact|
        artifact.parts.each do |part|
          tx = part.data["txHash"] if part.data.is_a?(Hash)
          return tx if tx.is_a?(String)
        end
      end
      nil
    end
  end

  # ─── IntentMandate ──────────────────────────────────────────────────────────

  # A mandate authorizing a payment intent.
  class IntentMandate
    attr_reader :mandate_id, :expires_at, :issuer, :max_amount, :currency

    def initialize(mandate_id:, expires_at:, issuer:, max_amount:, currency: "USDC")
      @mandate_id = mandate_id
      @expires_at = expires_at
      @issuer     = issuer
      @max_amount = max_amount
      @currency   = currency
    end

    def to_h
      {
        mandateId: @mandate_id,
        expiresAt: @expires_at,
        issuer:    @issuer,
        allowance: {
          maxAmount: @max_amount,
          currency:  @currency,
        },
      }
    end
  end

  # ─── A2A JSON-RPC client ────────────────────────────────────────────────────

  # A2A JSON-RPC client - send payments and manage tasks via the A2A protocol.
  #
  # @example
  #   card   = Remitmd::AgentCard.discover("https://remit.md")
  #   signer = Remitmd::PrivateKeySigner.new(ENV["REMITMD_KEY"])
  #   client = Remitmd::A2AClient.from_card(card, signer)
  #   task   = client.send(to: "0xRecipient...", amount: 10)
  #   puts task.status.state
  #
  class A2AClient
    CHAIN_IDS = {
      "base"         => 8453,
      "base-sepolia" => 84_532,
    }.freeze

    # @param endpoint [String] full A2A endpoint URL from the agent card
    # @param signer [#sign, #address] a signer for EIP-712 authentication
    # @param chain_id [Integer] chain ID
    # @param verifying_contract [String] verifying contract address
    def initialize(endpoint:, signer:, chain_id:, verifying_contract: "")
      parsed    = URI(endpoint)
      @base_url = "#{parsed.scheme}://#{parsed.host}#{parsed.port == parsed.default_port ? "" : ":#{parsed.port}"}"
      @path     = parsed.path.empty? ? "/a2a" : parsed.path
      @transport = HttpTransport.new(
        base_url:       @base_url,
        signer:         signer,
        chain_id:       chain_id,
        router_address: verifying_contract
      )
    end

    # Convenience constructor from an AgentCard and a signer.
    # @param card [AgentCard]
    # @param signer [#sign, #address]
    # @param chain [String] chain name (default: "base")
    # @param verifying_contract [String]
    # @return [A2AClient]
    def self.from_card(card, signer, chain: "base", verifying_contract: "")
      chain_id = CHAIN_IDS[chain] || CHAIN_IDS["base"]
      new(
        endpoint:            card.url,
        signer:              signer,
        chain_id:            chain_id,
        verifying_contract:  verifying_contract
      )
    end

    # Send a direct USDC payment via message/send.
    # @param to [String] recipient 0x address
    # @param amount [Numeric] amount in USDC
    # @param memo [String] optional memo
    # @param mandate [IntentMandate, nil] optional intent mandate
    # @return [A2ATask]
    def send(to:, amount:, memo: "", mandate: nil)
      nonce      = SecureRandom.hex(16)
      message_id = SecureRandom.hex(16)

      message = {
        messageId: message_id,
        role:      "user",
        parts: [
          {
            kind: "data",
            data: {
              model:  "direct",
              to:     to,
              amount: format("%.2f", amount),
              memo:   memo,
              nonce:  nonce,
            },
          },
        ],
      }

      message[:metadata] = { mandate: mandate.to_h } if mandate

      rpc("message/send", { message: message }, message_id)
    end

    # Fetch the current state of an A2A task by ID.
    # @param task_id [String]
    # @return [A2ATask]
    def get_task(task_id)
      rpc("tasks/get", { id: task_id }, task_id[0, 16])
    end

    # Cancel an in-progress A2A task.
    # @param task_id [String]
    # @return [A2ATask]
    def cancel_task(task_id)
      rpc("tasks/cancel", { id: task_id }, task_id[0, 16])
    end

    private

    def rpc(method, params, call_id)
      body = { jsonrpc: "2.0", id: call_id, method: method, params: params }
      data = @transport.post(@path, body)
      if data.is_a?(Hash) && data["error"]
        err_msg = data["error"]["message"] || JSON.generate(data["error"])
        raise RemitError.new("SERVER_ERROR", "A2A error: #{err_msg}")
      end
      result = data.is_a?(Hash) ? (data["result"] || data) : data
      A2ATask.new(result)
    end
  end
end
