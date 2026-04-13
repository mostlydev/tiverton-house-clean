# frozen_string_literal: true

FactoryBot.define do
  factory :ledger_transaction do
    sequence(:ledger_txn_id) { |n| "txn-#{n}" }
    source_type { 'broker_fill' }
    association :agent
    asset { 'USD' }
    booked_at { Time.current }
    description { 'Test transaction' }
    bootstrap_adjusted { false }
  end

  factory :ledger_entry do
    association :ledger_transaction
    sequence(:entry_seq) { |n| n }
    account_code { "agent:test-agent:cash" }
    amount { 1000.0 }
    asset { 'USD' }
    association :agent
    bootstrap_adjusted { false }
  end
end
