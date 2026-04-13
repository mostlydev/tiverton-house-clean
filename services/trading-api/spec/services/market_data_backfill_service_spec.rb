# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MarketDataBackfillService, type: :service do
  let(:broker) { instance_double(Alpaca::BrokerService) }
  let(:end_time) { Time.zone.parse('2026-04-03 20:00:00 UTC') }

  before do
    allow(MomentumMetricsCaptureService).to receive(:new).and_return(instance_double(MomentumMetricsCaptureService, call: []))
  end

  it 'backfills minute bars and refreshes momentum metrics for updated tickers' do
    allow(broker).to receive(:get_historical_bars).with(hash_including(ticker: 'AAPL')).and_return(
      success: true,
      bars: [
        { timestamp: '2026-04-03T19:58:00Z', open: 100.0, high: 101.0, low: 99.5, close: 100.5, volume: 1000, trade_count: 10, vwap: 100.2 },
        { timestamp: '2026-04-03T19:59:00Z', open: 100.5, high: 101.5, low: 100.2, close: 101.0, volume: 1100, trade_count: 12, vwap: 100.8 }
      ],
      next_page_token: nil
    )
    allow(broker).to receive(:get_historical_bars).with(hash_including(ticker: 'SPY')).and_return(
      success: true,
      bars: [
        { timestamp: '2026-04-03T19:59:00Z', open: 500.0, high: 501.0, low: 499.5, close: 500.8, volume: 10_000, trade_count: 100, vwap: 500.4 }
      ],
      next_page_token: nil
    )
    allow(broker).to receive(:get_historical_bars).with(hash_including(ticker: 'QQQ')).and_return(
      success: true,
      bars: [],
      next_page_token: nil
    )

    momentum_capture = instance_double(MomentumMetricsCaptureService, call: [])
    allow(MomentumMetricsCaptureService).to receive(:new).and_return(momentum_capture)

    result = described_class.new(
      days: 5,
      tickers: ['AAPL'],
      end_time: end_time,
      broker_service: broker
    ).call

    aggregate_failures do
      expect(result[:total_bars]).to eq(3)
      expect(result[:tickers]['AAPL'][:bars_written]).to eq(2)
      expect(result[:tickers]['SPY'][:bars_written]).to eq(1)
      expect(result[:updated_tickers]).to match_array(%w[AAPL SPY])
      expect(PriceSample.where(ticker: 'AAPL').count).to eq(2)
      expect(PriceSample.find_by!(ticker: 'SPY').close_price.to_f).to eq(500.8)
      expect(MomentumMetricsCaptureService).to have_received(:new).with(tickers: match_array(%w[AAPL SPY]))
    end
  end
end
