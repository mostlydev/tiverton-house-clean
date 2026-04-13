FactoryBot.define do
  factory :position do
    association :agent
    ticker { "AAPL" }
    qty { 100 }
    avg_entry_price { 145.0 }
    stop_loss { 130.0 }
    current_value { 14500.0 }
    opened_at { 1.day.ago }

    trait :tsla do
      ticker { "TSLA" }
      qty { 50 }
      avg_entry_price { 250.0 }
      current_value { 12500.0 }
    end

    trait :short do
      qty { -100 }
      avg_entry_price { 150.0 }
      current_value { -15000.0 }
    end

    trait :small do
      qty { 10 }
      current_value { 1450.0 }
    end
  end
end
