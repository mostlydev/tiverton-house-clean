# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ValueContextService, type: :service do
  let!(:agent) { create(:agent, :logan) }
  let(:base_time) { Time.current.change(sec: 0) }

  def create_metric(ticker:, metric:, value:, source: 'financial_datasets')
    TickerMetric.create!(
      ticker: ticker,
      metric: metric,
      value: value,
      observed_at: base_time,
      source: source,
      is_derived: true
    )
  end

  it 'returns a value-ranked watchlist with dividend calendar and value screen matches' do
    create(:position, agent: agent, ticker: 'JNJ', qty: 10, avg_entry_price: 100.0, current_value: 950.0)
    create(:watchlist, agent: agent, ticker: 'JNJ')
    create(:watchlist, agent: agent, ticker: 'CVX')

    create(:price_sample, ticker: 'JNJ', price: 100.0, sampled_at: base_time - 31.days, sample_minute: (base_time - 31.days).strftime('%Y-%m-%d %H:%M:00'))
    create(:price_sample, ticker: 'JNJ', price: 95.0, sampled_at: base_time - 1.minute, sample_minute: (base_time - 1.minute).strftime('%Y-%m-%d %H:%M:00'))
    create(:price_sample, ticker: 'CVX', price: 110.0, sampled_at: base_time - 31.days, sample_minute: (base_time - 31.days).strftime('%Y-%m-%d %H:%M:00'))
    create(:price_sample, ticker: 'CVX', price: 108.0, sampled_at: base_time - 1.minute, sample_minute: (base_time - 1.minute).strftime('%Y-%m-%d %H:%M:00'))

    create(:ticker_dividend_snapshot, ticker: 'JNJ', observed_at: base_time, next_ex_date: 7.days.from_now.to_date, payout_growth_yoy: 0.08)
    create(:ticker_dividend_snapshot, ticker: 'CVX', observed_at: base_time, next_ex_date: 20.days.from_now.to_date, payout_growth_yoy: 0.03)

    {
      'val_ev_ebitda' => 9.0,
      'val_fcf_yield' => 0.05,
      'health_current_ratio' => 1.1,
      'health_debt_to_equity' => 0.5,
      'health_interest_coverage' => 6.0,
      'profit_operating_margin' => 0.19,
      'growth_eps_yoy' => 0.07
    }.each { |metric, value| create_metric(ticker: 'JNJ', metric: metric, value: value) }
    {
      'val_ev_ebitda' => 13.0,
      'val_fcf_yield' => 0.04,
      'health_current_ratio' => 0.9,
      'health_debt_to_equity' => 1.6,
      'health_interest_coverage' => 4.0,
      'profit_operating_margin' => 0.12,
      'growth_eps_yoy' => 0.02
    }.each { |metric, value| create_metric(ticker: 'CVX', metric: metric, value: value) }

    create_metric(ticker: 'JNJ', metric: 'yield_change_30d', value: 0.005, source: ValueMetricsCaptureService::SOURCE)
    create_metric(ticker: 'JNJ', metric: 'payout_growth_yoy', value: 0.08, source: ValueMetricsCaptureService::SOURCE)
    create_metric(ticker: 'JNJ', metric: 'quality_value_score', value: 72.0, source: ValueMetricsCaptureService::SOURCE)
    create_metric(ticker: 'JNJ', metric: 'beaten_down_score', value: 55.0, source: ValueMetricsCaptureService::SOURCE)
    create_metric(ticker: 'CVX', metric: 'yield_change_30d', value: 0.001, source: ValueMetricsCaptureService::SOURCE)
    create_metric(ticker: 'CVX', metric: 'payout_growth_yoy', value: 0.03, source: ValueMetricsCaptureService::SOURCE)
    create_metric(ticker: 'CVX', metric: 'quality_value_score', value: 48.0, source: ValueMetricsCaptureService::SOURCE)
    create_metric(ticker: 'CVX', metric: 'beaten_down_score', value: 35.0, source: ValueMetricsCaptureService::SOURCE)

    payload = described_class.new(agent).call

    aggregate_failures do
      expect(payload[:leaders].first[:ticker]).to eq('JNJ')
      expect(payload[:leaders].first[:value_screen_match]).to eq(true)
      expect(payload[:watchlist].map { |row| row[:ticker] }).to eq(%w[JNJ CVX])
      expect(payload[:dividend_calendar].first[:ticker]).to eq('JNJ')
      expect(payload[:scan_summary][:value_screen_matches]).to eq(1)
    end
  end
end
