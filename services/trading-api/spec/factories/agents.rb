# Agent factory for tests
#
# IMPORTANT: Test Isolation
# -------------------------
# By default, agents are created with test-specific IDs (test-agent-N) that:
# - Do NOT map to real Discord user IDs
# - Will NOT trigger real Discord notifications
# - Are safe to use without mocking external services
#
# Production agent traits (:westin, :logan, etc.) use real agent IDs.
# Only use these when:
# - Testing Discord mention formatting (with DiscordService mocked)
# - Integration tests that verify agent ID handling
#
FactoryBot.define do
  factory :agent do
    # Default: test-specific IDs that don't map to real Discord users
    sequence(:agent_id) { |n| "test-agent-#{n}" }
    name { "Test Agent" }
    role { "trader" }
    style { "momentum" }
    status { "active" }

    after(:create) do |agent|
      create(:wallet, agent: agent) unless agent.wallet
    end

    # Test agent aliases with descriptive styles (safe - no real Discord mapping)
    trait :test_momentum do
      sequence(:agent_id) { |n| "test-momentum-#{n}" }
      name { "Test Momentum Trader" }
      style { "momentum" }
    end

    trait :test_value do
      sequence(:agent_id) { |n| "test-value-#{n}" }
      name { "Test Value Trader" }
      style { "value" }
    end

    trait :test_macro do
      sequence(:agent_id) { |n| "test-macro-#{n}" }
      name { "Test Macro Trader" }
      style { "macro" }
    end

    # ==========================================================
    # PRODUCTION AGENT TRAITS - USE WITH CAUTION IN TESTS
    # These map to real Discord user IDs in DiscordNotificationJob
    # Only use when testing Discord formatting with mocked DiscordService
    # ==========================================================

    trait :westin do
      agent_id { "westin" }
      name { "Westin" }
      role { "trader" }
      style { "momentum" }
    end

    trait :logan do
      agent_id { "logan" }
      name { "Logan" }
      role { "trader" }
      style { "value" }
    end

    trait :dundas do
      agent_id { "dundas" }
      name { "Dundas" }
      role { "trader" }
      style { "macro" }
    end

    trait :gerrard do
      agent_id { "gerrard" }
      name { "Gerrard" }
      role { "trader" }
      style { "contrarian" }
    end

    trait :tiverton do
      agent_id { "tiverton" }
      name { "Tiverton" }
      role { "coordinator" }
      style { nil }
    end

    trait :sentinel do
      agent_id { "sentinel" }
      name { "Sentinel" }
      role { "executor" }
      style { nil }
    end

    trait :allen do
      agent_id { "allen" }
      name { "Allen" }
      role { "analyst" }
      style { "research" }
    end

    # Test analyst alias (safe - no real Discord mapping)
    trait :test_analyst do
      sequence(:agent_id) { |n| "test-analyst-#{n}" }
      name { "Test Analyst" }
      role { "analyst" }
      style { "research" }
    end
  end
end
