FactoryBot.define do
  factory :wallet do
    association :agent
    wallet_size { 20000.0 }
    cash { 20000.0 }
    invested { 0.0 }

    trait :with_investments do
      cash { 10000.0 }
      invested { 10000.0 }
    end

    trait :fully_invested do
      cash { 0.0 }
      invested { 20000.0 }
    end
  end
end
