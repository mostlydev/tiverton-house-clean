FactoryBot.define do
  factory :news_article do
    sequence(:external_id) { |n| "news-#{n}" }
    headline { "Test headline" }
    source { "Test Source" }
    content { "Test content" }
    summary { "Test summary" }
    url { "https://example.com/news" }
    published_at { Time.current }
    fetched_at { Time.current }
    raw_json { {} }
  end

  factory :news_symbol do
    association :news_article
    symbol { "AAPL" }
  end
end
