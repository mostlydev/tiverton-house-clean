# frozen_string_literal: true

FactoryBot.define do
  factory :position_lot do
    association :agent
    ticker { 'AAPL' }
    qty { 10.0 }
    cost_basis_per_share { 150.0 }
    total_cost_basis { qty * cost_basis_per_share }
    opened_at { 1.day.ago }
    open_source_type { 'BrokerFill' }
    open_source_id { 1 }
    closed_at { nil }
    bootstrap_adjusted { false }

    trait :closed do
      closed_at { Time.current }
      close_source_type { 'BrokerFill' }
      close_source_id { 2 }
      realized_pnl { 100.0 }
    end

    trait :bootstrap do
      bootstrap_adjusted { true }
      association :reconciliation_provenance
      open_source_type { 'ReconciliationProvenance' }
    end

    trait :short do
      qty { -10.0 }
      total_cost_basis { qty.abs * cost_basis_per_share }
    end

    trait :with_gain do
      realized_pnl { 500.0 }
    end

    trait :with_loss do
      realized_pnl { -250.0 }
    end
  end
end
