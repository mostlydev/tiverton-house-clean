FactoryBot.define do
  factory :trade do
    association :agent
    ticker { "AAPL" }
    side { "BUY" }
    qty_requested { 100 }
    amount_requested { nil }
    order_type { "MARKET" }
    limit_price { nil }
    stop_price { nil }
    trail_percent { nil }
    trail_amount { nil }
    status { "PROPOSED" }
    thesis { "Test trade" }
    stop_loss { side == "BUY" ? 130.0 : nil }
    target_price { nil }
    is_urgent { false }
    approved_by { nil }
    approved_at { nil }
    confirmed_at { nil }
    denial_reason { nil }
    execution_error { nil }
    executed_by { nil }
    execution_started_at { nil }
    execution_completed_at { nil }
    alpaca_order_id { nil }
    qty_filled { nil }
    avg_fill_price { nil }
    filled_value { nil }

    trait :proposed do
      status { "PROPOSED" }
    end

    trait :approved do
      status { "APPROVED" }
      approved_by { "tiverton" }
      approved_at { Time.current }
      confirmed_at { approved_at }
    end

    trait :confirmed do
      status { "APPROVED" }
      approved_by { "tiverton" }
      approved_at { Time.current }
      confirmed_at { Time.current }
    end

    trait :executing do
      status { "EXECUTING" }
      approved_by { "tiverton" }
      approved_at { 5.minutes.ago }
      confirmed_at { approved_at }
      executed_by { "sentinel" }
      execution_started_at { Time.current }
      alpaca_order_id { "test-order-#{SecureRandom.hex(4)}" }
    end

    trait :filled do
      status { "FILLED" }
      approved_by { "tiverton" }
      approved_at { 10.minutes.ago }
      confirmed_at { approved_at }
      executed_by { "sentinel" }
      execution_started_at { 5.minutes.ago }
      execution_completed_at { Time.current }
      qty_filled { 100 }
      avg_fill_price { 150.0 }
      filled_value { 15000.0 }
      alpaca_order_id { "test-order-#{SecureRandom.hex(4)}" }
    end

    trait :sell do
      side { "SELL" }
    end

    trait :limit_order do
      order_type { "LIMIT" }
      limit_price { 145.0 }
    end

    trait :stop_order do
      order_type { "STOP" }
      stop_price { 155.0 }
    end

    trait :urgent do
      is_urgent { true }
    end

    trait :with_sell_all do
      thesis { "Test sell\nSELL_ALL\nNOTIONAL_OK" }
    end

    trait :with_short_ok do
      thesis { "Test short\nSHORT_OK" }
    end

    trait :with_notional_ok do
      thesis { "Test notional\nNOTIONAL_OK" }
    end

    trait :notional do
      qty_requested { nil }
      amount_requested { 5000.0 }
    end
  end
end
