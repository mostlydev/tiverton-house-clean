# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TraderContextPrimeService, type: :service do
  let(:backfill_service_class) { class_double(MarketDataBackfillService) }
  let(:dividend_service_class) { class_double(DividendSnapshotRefreshService) }
  let(:backfill_service) { instance_double(MarketDataBackfillService) }
  let(:dividend_service) { instance_double(DividendSnapshotRefreshService) }
  let(:end_time) { Time.zone.parse('2026-04-03 20:00:00 UTC') }

  before do
    allow(backfill_service_class).to receive(:new).and_return(backfill_service)
    allow(dividend_service_class).to receive(:new).and_return(dividend_service)
    allow(backfill_service).to receive(:call).and_return({ total_bars: 123, updated_tickers: %w[CVX JNJ SPY QQQ] })
    allow(dividend_service).to receive(:call).and_return([double(:snapshot_one), double(:snapshot_two)])
  end

  it 'runs market-data backfill first and then refreshes dividend snapshots for equity tickers' do
    result = described_class.new(
      days: 20,
      tickers: %w[jnj cvx],
      end_time: end_time,
      market_data_backfill_service_class: backfill_service_class,
      dividend_snapshot_refresh_service_class: dividend_service_class
    ).call

    aggregate_failures do
      expect(backfill_service_class).to have_received(:new).with(
        days: 20,
        tickers: %w[CVX JNJ],
        include_benchmarks: true,
        end_time: end_time
      )
      expect(dividend_service_class).to have_received(:new).with(
        tickers: %w[CVX JNJ],
        observed_at: end_time
      )
      expect(result[:dividend_snapshots_written]).to eq(2)
      expect(result[:backfill][:total_bars]).to eq(123)
      expect(result[:equity_tickers]).to eq(%w[CVX JNJ])
    end
  end
end
