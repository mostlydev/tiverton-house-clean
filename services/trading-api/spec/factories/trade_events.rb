FactoryBot.define do
  factory :trade_event do
    trade { nil }
    event_type { "MyString" }
    actor { "MyString" }
    details { "" }
  end
end
