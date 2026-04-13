# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TickerMetricsRefreshService do
  describe '.enqueue_refresh' do
    it 'enqueues fetchers for stale metrics' do
      allow(Rails.cache).to receive(:read).and_return(false)
      allow(Rails.cache).to receive(:write)
      allow(TickerMetricsRefreshJob).to receive(:perform_later)

      enqueued = described_class.enqueue_refresh(
        ticker: 'AAPL',
        metrics: %w[social_mentions_1h fs_income_revenue],
        period_type: 'quarterly',
        history: true,
        limit: 4
      )

      expect(enqueued).to match_array([:apewisdom, :fundamentals])
      expect(TickerMetricsRefreshJob).to have_received(:perform_later).twice
    end

    it 'honors fetcher rate limits' do
      allow(Rails.cache).to receive(:read) do |key|
        key.to_s.include?('rate_limit:apewisdom')
      end
      allow(Rails.cache).to receive(:write)
      allow(TickerMetricsRefreshJob).to receive(:perform_later)

      enqueued = described_class.enqueue_refresh(
        ticker: 'AAPL',
        metrics: %w[social_mentions_1h fs_income_revenue],
        period_type: 'quarterly',
        history: true,
        limit: 4
      )

      expect(enqueued).to match_array([:fundamentals])
      expect(TickerMetricsRefreshJob).to have_received(:perform_later).once
    end

    it 'skips unknown metrics' do
      allow(TickerMetricsRefreshJob).to receive(:perform_later)

      enqueued = described_class.enqueue_refresh(
        ticker: 'AAPL',
        metrics: %w[unknown_metric],
        period_type: nil,
        history: false,
        limit: 0
      )

      expect(enqueued).to eq([])
      expect(TickerMetricsRefreshJob).not_to have_received(:perform_later)
    end
  end
end
