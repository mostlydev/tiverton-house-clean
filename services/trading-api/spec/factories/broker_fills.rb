# frozen_string_literal: true

FactoryBot.define do
  factory :broker_fill do
    association :agent
    broker_order { nil }
    trade { nil }

    sequence(:broker_fill_id) { |n| "fill-#{n}-#{SecureRandom.hex(4)}" }
    ticker { 'AAPL' }
    side { 'buy' }
    qty { 10.0 }
    price { 150.0 }
    value { qty * price }
    executed_at { Time.current }
    fill_id_confidence { 'broker_verified' }
    raw_fill { {} }

    trait :buy do
      side { 'buy' }
    end

    trait :sell do
      side { 'sell' }
    end
  end
end
