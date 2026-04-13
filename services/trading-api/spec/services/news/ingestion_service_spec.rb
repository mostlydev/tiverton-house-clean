# frozen_string_literal: true

require 'rails_helper'

RSpec.describe News::IngestionService do
  let(:payload) do
    [
      {
        'id' => 'abc-1',
        'headline' => 'Headline 1',
        'source' => 'Source',
        'content' => 'Content',
        'summary' => 'Summary',
        'url' => 'https://example.com/1',
        'created_at' => '2026-02-03T12:00:00Z',
        'symbols' => ['AAPL', 'MSFT']
      }
    ]
  end

  it 'creates news article and symbols' do
    service = described_class.new(payload, fetched_at: Time.current)

    expect { service.call }.to change(NewsArticle, :count).by(1)
      .and change(NewsSymbol, :count).by(2)

    article = NewsArticle.last
    expect(article.external_id).to eq('abc-1')
    expect(article.symbols).to contain_exactly('AAPL', 'MSFT')
  end

  it 'deduplicates by external_id' do
    create(:news_article, external_id: 'abc-1')

    service = described_class.new(payload, fetched_at: Time.current)

    expect { service.call }.not_to change(NewsArticle, :count)
  end
end
