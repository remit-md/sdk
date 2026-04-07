require_relative "lib/remitmd"

Gem::Specification.new do |s|
  s.name        = "remitmd"
  s.version     = Remitmd::VERSION
  s.summary     = "DEPRECATED: Use pay-cli or pay SDKs instead. See https://pay-skill.com/docs"
  s.description = "DEPRECATED: This gem is no longer maintained. Use pay-cli (cargo install pay-cli) " \
                  "or pay SDKs (pip install pay-sdk / npm install @pay-skill/sdk). " \
                  "See https://pay-skill.com/docs for migration."
  s.authors     = ["remit.md"]
  s.email       = ["hello@remit.md"]
  s.homepage    = "https://pay-skill.com"
  s.license     = "MIT"
  s.metadata    = {
    "homepage_uri"      => "https://pay-skill.com",
    "source_code_uri"   => "https://github.com/remit-md/pay-sdk",
    "changelog_uri"     => "https://github.com/remit-md/pay-sdk/releases",
  }
  s.post_install_message = "WARNING: remitmd is deprecated. Use pay-cli or pay SDKs instead. See https://pay-skill.com/docs"

  s.required_ruby_version = ">= 3.0"

  s.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]

  # No external runtime dependencies — stdlib only (net/http, openssl, json, bigdecimal)
  # This makes remitmd trivially installable in any Ruby environment.

  s.add_development_dependency "rspec",  "~> 3.12"
  s.add_development_dependency "rubocop", "~> 1.60"
end
