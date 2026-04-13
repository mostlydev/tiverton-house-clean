# frozen_string_literal: true

FactoryBot.define do
  factory :reconciliation_provenance do
    sequence(:run_id) { |n| "reconciliation-#{n}-#{Time.current.to_i}" }
    runner_script { 'test_script.rb' }
    runner_version { '1.0.0' }
    invocation_params { {} }
    operator { 'test' }
    started_at { Time.current }
    completed_at { Time.current }
    status { 'completed' }

    trait :bootstrap do
      runner_script { 'bootstrap.rb' }
      notes { 'Bootstrap reconciliation' }
    end

    trait :alpaca_sync do
      runner_script { 'alpaca_sync.rb' }
      notes { 'Alpaca position sync' }
    end
  end
end
