# frozen_string_literal: true

FactoryBot.define do
  factory :broker_order do
    association :trade
    agent { trade.agent }

    sequence(:broker_order_id) { |n| "order-#{n}-#{SecureRandom.hex(4)}" }
    sequence(:client_order_id) { |n| "client-order-#{n}-#{SecureRandom.hex(4)}" }
    ticker { trade.ticker }
    side { trade.side.to_s.downcase }
    order_type { trade.order_type.to_s.downcase.presence || 'market' }
    asset_class { 'us_equity' }
    time_in_force { 'day' }
    requested_tif { 'day' }
    effective_tif { 'day' }
    qty_requested { trade.qty_requested || 10.0 }
    notional_requested { trade.amount_requested }
    limit_price { trade.limit_price }
    stop_price { trade.stop_price }
    trail_percent { trade.trail_percent }
    status { 'filled' }
    submitted_at { 5.minutes.ago }
    filled_at { Time.current }
    raw_request { {} }
    raw_response { {} }
  end
end
