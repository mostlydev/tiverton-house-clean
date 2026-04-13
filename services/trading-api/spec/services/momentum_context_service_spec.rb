# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MomentumContextService, type: :service do
  let!(:agent) { create(:agent, :westin) }
  let(:base_time) { Time.current.change(sec: 0) }

  def create_sample(ticker:, price:, sampled_at:)
    create(
      :price_sample,
      ticker: ticker,
      price: price,
      sampled_at: sampled_at,
      sample_minute: sampled_at.strftime('%Y-%m-%d %H:%M:00')
    )
  end

  def create_metric(ticker:, metric:, value:)
    TickerMetric.create!(
      ticker: ticker,
      metric: metric,
      value: value,
      observed_at: Time.current,
      source: MomentumMetricsCaptureService::SOURCE,
      is_derived: true
    )
  end

  it 'returns a momentum-ranked watchlist with unusual-volume and benchmark context' do
    create(:position, agent: agent, ticker: 'AAPL', qty: 10, avg_entry_price: 100.0, current_value: 1100.0)
    Watchlist.create!(agent: agent, ticker: 'AAPL', source: 'manual')
    Watchlist.create!(agent: agent, ticker: 'TSLA', source: 'manual')

    create_sample(ticker: 'AAPL', price: 100.0, sampled_at: base_time - 16.minutes)
    create_sample(ticker: 'AAPL', price: 110.0, sampled_at: base_time - 1.minute)
    create_sample(ticker: 'TSLA', price: 100.0, sampled_at: base_time - 16.minutes)
    create_sample(ticker: 'TSLA', price: 101.0, sampled_at: base_time - 1.minute)
    create_sample(ticker: 'SPY', price: 100.0, sampled_at: base_time - 16.minutes)
    create_sample(ticker: 'SPY', price: 104.0, sampled_at: base_time - 1.minute)
    create_sample(ticker: 'QQQ', price: 100.0, sampled_at: base_time - 16.minutes)
    create_sample(ticker: 'QQQ', price: 106.0, sampled_at: base_time - 1.minute)

    create_metric(ticker: 'AAPL', metric: 'volume_spike_1m', value: 6.0)
    create_metric(ticker: 'AAPL', metric: 'volume_spike_5m', value: 5.5)
    create_metric(ticker: 'AAPL', metric: 'unusual_volume_flag', value: 1.0)
    create_metric(ticker: 'TSLA', metric: 'volume_spike_1m', value: 1.2)
    create_metric(ticker: 'TSLA', metric: 'volume_spike_5m', value: 1.0)
    create_metric(ticker: 'TSLA', metric: 'unusual_volume_flag', value: 0.0)
    create_metric(ticker: 'SPY', metric: 'volume_spike_1m', value: 1.1)
    create_metric(ticker: 'SPY', metric: 'volume_spike_5m', value: 1.0)
    create_metric(ticker: 'QQQ', metric: 'volume_spike_1m', value: 1.3)
    create_metric(ticker: 'QQQ', metric: 'volume_spike_5m', value: 1.1)

    payload = described_class.new(agent).call

    aggregate_failures do
      expect(payload[:leaders].first[:ticker]).to eq('AAPL')
      expect(payload[:leaders].first[:unusual_volume]).to eq(true)
      expect(payload[:leaders].first[:in_position]).to eq(true)
      expect(payload[:watchlist].map { |row| row[:ticker] }).to eq(%w[AAPL TSLA])
      expect(payload[:benchmarks].map { |row| row[:ticker] }).to eq(%w[SPY QQQ])
      expect(payload[:scan_summary][:unusual_volume_count]).to eq(1)
    end
  end
end
