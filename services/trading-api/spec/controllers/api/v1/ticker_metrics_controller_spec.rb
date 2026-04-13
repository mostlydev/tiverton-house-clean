# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::TickerMetricsController, type: :controller do
  before do
    allow(controller).to receive(:require_local_request).and_return(true)
    allow(AppConfig).to receive(:ticker_metrics_ttl_seconds).and_return(300)
  end

  describe 'GET #index' do
    it 'returns only fresh metrics by default' do
      TickerMetric.create!(
        ticker: 'AAPL',
        metric: 'social_mentions_1h',
        value: 12,
        source: 'test',
        observed_at: 2.minutes.ago
      )

      get :index, params: { ticker: 'AAPL' }, format: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['metrics'].length).to eq(1)
      expect(body['metrics'][0]['metric']).to eq('social_mentions_1h')
      expect(body['metrics'][0]['fresh']).to eq(true)
    end

    it 'filters stale metrics unless include_stale is true' do
      TickerMetric.create!(
        ticker: 'MSFT',
        metric: 'sentiment_score',
        value: -0.4,
        source: 'test',
        observed_at: 20.minutes.ago
      )

      get :index, params: { ticker: 'MSFT' }, format: :json
      body = JSON.parse(response.body)
      expect(body['metrics']).to eq([])

      get :index, params: { ticker: 'MSFT', include_stale: true }, format: :json
      body = JSON.parse(response.body)
      expect(body['metrics'].length).to eq(1)
      expect(body['metrics'][0]['fresh']).to eq(false)
    end

    it 'enqueues refresh when requested and metrics are stale' do
      TickerMetric.create!(
        ticker: 'GME',
        metric: 'social_mentions_1h',
        value: 55,
        source: 'quiver',
        observed_at: 20.minutes.ago
      )

      allow(TickerMetricsRefreshService).to receive(:enqueue_refresh).and_return([ 'quiver_wsb' ])

      get :index, params: { ticker: 'GME', metrics: 'social_mentions_1h', include_stale: true, refresh: true }, format: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['refresh']['requested']).to eq(true)
      expect(body['refresh']['enqueued']).to eq([ 'quiver_wsb' ])
    end

    it 'returns history ordered by period_end when requested' do
      TickerMetric.create!(
        ticker: 'IBM',
        metric: 'fundamentals_quarterly_eps',
        value: 1.0,
        source: 'test',
        period_type: 'quarterly',
        period_end: Date.new(2024, 12, 31),
        observed_at: 1.hour.ago
      )
      TickerMetric.create!(
        ticker: 'IBM',
        metric: 'fundamentals_quarterly_eps',
        value: 1.5,
        source: 'test',
        period_type: 'quarterly',
        period_end: Date.new(2025, 3, 31),
        observed_at: 30.minutes.ago
      )

      get :index, params: { ticker: 'IBM', period_type: 'quarterly', history: true, limit: 2, include_stale: true }, format: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['metrics'].length).to eq(2)
      expect(body['metrics'][0]['period_end']).to eq('2025-03-31')
      expect(body['metrics'][1]['period_end']).to eq('2024-12-31')
    end
  end

  describe 'POST #bulk' do
    it 'inserts metrics in a single request' do
      payload = [
        { ticker: 'NVDA', metric: 'social_mentions_1h', value: 42, source: 'alpha' },
        {
          ticker: 'NVDA',
          metric: 'fundamentals_quarterly_eps',
          value: 1.25,
          source: 'alpha',
          period_type: 'quarterly',
          period_end: '2025-12-31',
          fiscal_year: 2025,
          fiscal_quarter: 4,
          is_derived: false
        }
      ]

      expect do
        post :bulk, params: { metrics: payload }, format: :json
      end.to change(TickerMetric, :count).by(2)

      expect(response).to have_http_status(:ok)
    end
  end
end
