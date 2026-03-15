# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module RemitMd
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
    #   card = RemitMd::AgentCard.discover("https://remit.md")
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
end
