# frozen_string_literal: true

FactoryBot.define do
  factory :price_sample do
    ticker { 'AAPL' }
    price { 150.0 }
    sampled_at { Time.current }
    sample_minute { Time.current.strftime('%Y-%m-%d %H:%M:00') }
    source { 'price_update' }
  end
end
