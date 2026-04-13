# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MomentumMetricsCaptureService, type: :service do
  let(:base_time) { Time.current.change(sec: 0) }

  def create_sample(ticker:, price:, sampled_at:, volume:)
    create(
      :price_sample,
      ticker: ticker,
      price: price,
      open_price: price,
      high_price: price,
      low_price: price,
      close_price: price,
      volume: volume,
      sampled_at: sampled_at,
      sample_minute: sampled_at.strftime('%Y-%m-%d %H:%M:00')
    )
  end

  it 'persists return, relative strength, and unusual-volume metrics' do
    (25).downto(6).each do |minutes_ago|
      next if minutes_ago == 16

      sampled_at = base_time - minutes_ago.minutes
      create_sample(ticker: 'AAPL', price: 100.0, sampled_at: sampled_at, volume: 100)
    end

    create_sample(ticker: 'AAPL', price: 100.0, sampled_at: base_time - 16.minutes, volume: 100)
    create_sample(ticker: 'SPY', price: 100.0, sampled_at: base_time - 16.minutes, volume: 1_000)
    create_sample(ticker: 'QQQ', price: 100.0, sampled_at: base_time - 16.minutes, volume: 1_000)

    [5, 4, 3, 2, 1].each do |minutes_ago|
      create_sample(ticker: 'AAPL', price: 110.0, sampled_at: base_time - minutes_ago.minutes, volume: 600)
    end
    create_sample(ticker: 'SPY', price: 102.0, sampled_at: base_time - 1.minute, volume: 1_200)
    create_sample(ticker: 'QQQ', price: 105.0, sampled_at: base_time - 1.minute, volume: 1_400)

    described_class.new(tickers: ['AAPL']).call

    latest = TickerMetric.latest_for(ticker: 'AAPL', sources: [MomentumMetricsCaptureService::SOURCE]).index_by(&:metric)

    aggregate_failures do
      expect(latest.fetch('price_return_15m').value.to_f).to be_within(0.0001).of(0.10)
      expect(latest.fetch('rs_vs_spy_15m').value.to_f).to be_within(0.0001).of(0.08)
      expect(latest.fetch('rs_vs_qqq_15m').value.to_f).to be_within(0.0001).of(0.05)
      expect(latest.fetch('volume_spike_1m').value.to_f).to be_within(0.0001).of(6.0)
      expect(latest.fetch('volume_spike_5m').value.to_f).to be_within(0.0001).of(6.0)
      expect(latest.fetch('unusual_volume_flag').value.to_f).to eq(1.0)
    end
  end
end
