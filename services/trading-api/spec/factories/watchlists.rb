# frozen_string_literal: true

FactoryBot.define do
  factory :watchlist do
    association :agent
    ticker { 'AAPL' }
    source { 'manual' }
  end
end
