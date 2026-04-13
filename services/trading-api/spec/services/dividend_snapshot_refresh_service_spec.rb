# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DividendSnapshotRefreshService, type: :service do
  let(:observed_at) { Time.zone.parse('2026-04-03 10:00:00 UTC') }
  let(:broker_service) { instance_double(Alpaca::BrokerService) }

  before do
    create(
      :price_sample,
      ticker: 'CVX',
      price: 100.0,
      sampled_at: observed_at - 1.minute,
      sample_minute: (observed_at - 1.minute).strftime('%Y-%m-%d %H:%M:00')
    )

    TickerMetric.create!(
      ticker: 'CVX',
      metric: 'fs_income_dividends_per_share',
      value: 1.25,
      period_type: 'quarterly',
      period_end: Date.new(2026, 3, 31),
      observed_at: observed_at,
      source: 'financial_datasets'
    )
    TickerMetric.create!(
      ticker: 'CVX',
      metric: 'fs_income_dividends_per_share',
      value: 1.0,
      period_type: 'quarterly',
      period_end: Date.new(2025, 3, 31),
      observed_at: observed_at - 1.day,
      source: 'financial_datasets'
    )
    TickerMetric.create!(
      ticker: 'CVX',
      metric: 'fs_income_eps_diluted',
      value: 2.5,
      period_type: 'quarterly',
      period_end: Date.new(2026, 3, 31),
      observed_at: observed_at,
      source: 'financial_datasets'
    )
    create(
      :ticker_dividend_snapshot,
      ticker: 'CVX',
      observed_at: observed_at - 35.days,
      dividend_yield: 0.03,
      payout_growth_yoy: 0.02
    )

    allow(broker_service).to receive(:get_corporate_actions).and_return(
      success: true,
      actions: [
        {
          id: 'ca-1',
          symbol: 'CVX',
          ex_date: Date.new(2026, 4, 20),
          pay_date: Date.new(2026, 6, 10),
          declaration_date: Date.new(2026, 3, 15),
          record_date: Date.new(2026, 4, 22),
          cash: 1.25
        }
      ]
    )
    allow_any_instance_of(ValueMetricsCaptureService).to receive(:call).and_return([])
  end

  it 'persists a dividend snapshot with forward dates and derived payout fields' do
    snapshot = described_class.new(
      tickers: ['CVX'],
      broker_service: broker_service,
      observed_at: observed_at
    ).call.first

    aggregate_failures do
      expect(snapshot.ticker).to eq('CVX')
      expect(snapshot.next_ex_date).to eq(Date.new(2026, 4, 20))
      expect(snapshot.next_pay_date).to eq(Date.new(2026, 6, 10))
      expect(snapshot.annualized_dividend.to_f).to be_within(0.0001).of(5.0)
      expect(snapshot.dividend_yield.to_f).to be_within(0.0001).of(0.05)
      expect(snapshot.yield_change_30d.to_f).to be_within(0.0001).of(0.02)
      expect(snapshot.payout_ratio.to_f).to be_within(0.0001).of(0.5)
      expect(snapshot.payout_growth_yoy.to_f).to be_within(0.0001).of(0.25)
    end
  end

  it 'falls back to a historical price sample when no prior dividend snapshot exists' do
    TickerDividendSnapshot.delete_all
    create(
      :price_sample,
      ticker: 'CVX',
      price: 80.0,
      sampled_at: observed_at - 31.days,
      sample_minute: (observed_at - 31.days).strftime('%Y-%m-%d %H:%M:00')
    )

    snapshot = described_class.new(
      tickers: ['CVX'],
      broker_service: broker_service,
      observed_at: observed_at
    ).call.first

    aggregate_failures do
      expect(snapshot.yield_change_30d.to_f).to be_within(0.0001).of(-0.0125)
      expect(snapshot.meta['yield_change_30d_source']).to eq('historical_price_30d')
    end
  end
end
