FactoryBot.define do
  factory :research_entity do
    name { "Apple Inc" }
    entity_type { "company" }
    summary { "Consumer electronics and services company" }
    ticker { "AAPL" }
    data { {} }

    trait :person do
      name { "Tim Cook" }
      entity_type { "person" }
      ticker { nil }
      summary { "CEO of Apple Inc" }
    end

    trait :sector do
      name { "Technology" }
      entity_type { "sector" }
      ticker { nil }
      summary { "Technology sector" }
    end

    trait :theme do
      name { "AI Infrastructure" }
      entity_type { "theme" }
      ticker { nil }
      summary { "Artificial intelligence infrastructure buildout" }
    end

    trait :regulator do
      name { "SEC" }
      entity_type { "regulator" }
      ticker { nil }
      summary { "Securities and Exchange Commission" }
    end
  end

  factory :research_relationship do
    association :source_entity, factory: :research_entity
    association :target_entity, factory: :research_entity, name: "Microsoft Corp", ticker: "MSFT"
    relationship_type { "competes_with" }
    strength { "moderate" }
  end

  factory :investigation do
    title { "AI Chip Supply Chain Analysis" }
    status { "active" }
    thesis { "AI chip demand will outpace supply through 2027" }

    trait :completed do
      status { "completed" }
      recommendation { "Overweight semiconductor suppliers" }
    end

    trait :paused do
      status { "paused" }
    end
  end

  factory :investigation_entity do
    association :investigation
    association :research_entity
    role { "target" }
  end

  factory :research_note do
    association :notable, factory: :research_entity
    note_type { "finding" }
    content { "Q4 revenue exceeded estimates by 8%" }

    trait :risk_flag do
      note_type { "risk_flag" }
      content { "Regulatory headwinds in EU market" }
    end

    trait :catalyst do
      note_type { "catalyst" }
      content { "Product launch scheduled for Q2" }
    end

    trait :on_investigation do
      association :notable, factory: :investigation
    end
  end
end
