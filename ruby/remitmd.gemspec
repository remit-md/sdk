require_relative "lib/remitmd"

Gem::Specification.new do |s|
  s.name        = "remitmd"
  s.version     = Remitmd::VERSION
  s.summary     = "remit.md — universal payment protocol SDK for AI agents"
  s.description = "Send and receive USDC via the remit.md protocol. Supports direct payments, " \
                  "escrow, metered tabs, payment streams, bounties, and security deposits. " \
                  "Includes MockRemit for zero-network testing."
  s.authors     = ["remit.md"]
  s.email       = ["hello@remit.md"]
  s.homepage    = "https://remit.md"
  s.license     = "MIT"
  s.metadata    = {
    "homepage_uri"      => "https://remit.md",
    "source_code_uri"   => "https://github.com/remit-md/sdk",
    "changelog_uri"     => "https://github.com/remit-md/sdk/releases",
  }

  s.required_ruby_version = ">= 3.0"

  s.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]

  # No external runtime dependencies — stdlib only (net/http, openssl, json, bigdecimal)
  # This makes remitmd trivially installable in any Ruby environment.

  s.add_development_dependency "rspec",  "~> 3.12"
  s.add_development_dependency "rubocop", "~> 1.60"
end
