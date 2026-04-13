# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::TickerDiscoverabilityController, type: :controller do
  before do
    allow(controller).to receive(:require_local_request).and_return(true)
    allow(AppConfig).to receive(:ticker_metrics_ttl_seconds).and_return(300)
  end

  it 'returns ranked results for a metric' do
    TickerMetric.create!(
      ticker: 'AAA',
      metric: 'social_mentions_24h',
      value: 10,
      source: 'apewisdom',
      observed_at: 1.minute.ago
    )
    TickerMetric.create!(
      ticker: 'BBB',
      metric: 'social_mentions_24h',
      value: 50,
      source: 'apewisdom',
      observed_at: 2.minutes.ago
    )

    get :index, params: { metric: 'social_mentions_24h', source: 'apewisdom' }, format: :json

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['results'].length).to eq(2)
    expect(body['results'][0]['ticker']).to eq('BBB')
  end

  it 'filters to holdings when requested' do
    agent = create(:agent)
    create(:position, agent: agent, ticker: 'HOLD', qty: 1, avg_entry_price: 10)

    TickerMetric.create!(
      ticker: 'HOLD',
      metric: 'social_mentions_24h',
      value: 5,
      source: 'apewisdom',
      observed_at: 1.minute.ago
    )
    TickerMetric.create!(
      ticker: 'OTHER',
      metric: 'social_mentions_24h',
      value: 100,
      source: 'apewisdom',
      observed_at: 1.minute.ago
    )

    get :index, params: { metric: 'social_mentions_24h', source: 'apewisdom', only_holdings: true }, format: :json

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['results'].length).to eq(1)
    expect(body['results'][0]['ticker']).to eq('HOLD')
  end
end
