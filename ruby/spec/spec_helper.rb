# frozen_string_literal: true

# Coverage gate — enforced in CI only to avoid slowing local dev.
# Target from MASTER.md: 50%. Initial gate: 35% (compliance tests skipped without server).
if ENV["CI"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    minimum_coverage 35
  end
end

require "remitmd"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.order = :random
  Kernel.srand config.seed
end
