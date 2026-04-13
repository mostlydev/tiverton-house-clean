# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ValueMetricsCaptureService, type: :service do
  let(:observed_at) { Time.zone.parse('2026-04-03 10:00:00 UTC') }

  before do
    create(
      :price_sample,
      ticker: 'JNJ',
      price: 100.0,
      sampled_at: observed_at - 20.days,
      sample_minute: (observed_at - 20.days).strftime('%Y-%m-%d %H:%M:00')
    )
    create(
      :price_sample,
      ticker: 'JNJ',
      price: 90.0,
      sampled_at: observed_at - 1.minute,
      sample_minute: (observed_at - 1.minute).strftime('%Y-%m-%d %H:%M:00')
    )
    create(
      :ticker_dividend_snapshot,
      ticker: 'JNJ',
      observed_at: observed_at,
      dividend_yield: 0.035,
      yield_change_30d: 0.005,
      payout_growth_yoy: 0.08
    )

    {
      'val_ev_ebitda' => 10.0,
      'val_fcf_yield' => 0.05,
      'health_current_ratio' => 1.2,
      'health_debt_to_equity' => 0.6,
      'health_interest_coverage' => 8.0,
      'profit_operating_margin' => 0.18,
      'growth_eps_yoy' => 0.06
    }.each do |metric, value|
      TickerMetric.create!(
        ticker: 'JNJ',
        metric: metric,
        value: value,
        observed_at: observed_at,
        source: 'financial_datasets',
        is_derived: true
      )
    end
  end

  it 'persists slower value signals from fundamentals, dividend snapshots, and drawdown' do
    described_class.new(tickers: ['JNJ'], observed_at: observed_at).call

    latest = TickerMetric.latest_for(ticker: 'JNJ', sources: [ValueMetricsCaptureService::SOURCE]).index_by(&:metric)

    aggregate_failures do
      expect(latest.fetch('yield_change_30d').value.to_f).to be_within(0.0001).of(0.005)
      expect(latest.fetch('payout_growth_yoy').value.to_f).to be_within(0.0001).of(0.08)
      expect(latest.fetch('quality_value_score').value.to_f).to be > 50.0
      expect(latest.fetch('beaten_down_score').value.to_f).to be > 30.0
    end
  end
end
