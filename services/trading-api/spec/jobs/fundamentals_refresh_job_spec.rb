# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FundamentalsRefreshJob do
  let(:agent) { create(:agent) }

  before do
    mock_all_external_services!
  end

  describe '#perform' do
    it 'enqueues per-ticker refresh jobs for tracked equity positions' do
      create(:position, agent: agent, ticker: 'AAPL', qty: 100, asset_class: 'us_equity')
      create(:position, agent: agent, ticker: 'AMD', qty: 50, asset_class: 'us_equity')

      expect {
        described_class.new.perform
      }.to have_enqueued_job(TickerMetricsRefreshJob).exactly(2).times
    end

    it 'skips crypto pairs' do
      create(:position, agent: agent, ticker: 'BTC/USD', qty: 1, asset_class: 'crypto')
      create(:position, agent: agent, ticker: 'AAPL', qty: 100, asset_class: 'us_equity')

      expect {
        described_class.new.perform
      }.to have_enqueued_job(TickerMetricsRefreshJob).exactly(1).times
    end

    it 'skips known ETFs' do
      create(:position, agent: agent, ticker: 'SPY', qty: 10, asset_class: 'us_equity')
      create(:position, agent: agent, ticker: 'GLD', qty: 20, asset_class: 'us_equity')
      create(:position, agent: agent, ticker: 'AAPL', qty: 100, asset_class: 'us_equity')

      expect {
        described_class.new.perform
      }.to have_enqueued_job(TickerMetricsRefreshJob).exactly(1).times
    end

    it 'skips zero-quantity positions' do
      create(:position, agent: agent, ticker: 'AAPL', qty: 0, asset_class: 'us_equity')
      create(:position, agent: agent, ticker: 'AMD', qty: 50, asset_class: 'us_equity')

      expect {
        described_class.new.perform
      }.to have_enqueued_job(TickerMetricsRefreshJob).exactly(1).times
    end

    it 'deduplicates tickers across agents' do
      other_agent = create(:agent, agent_id: 'other', name: 'Other')
      create(:position, agent: agent, ticker: 'AAPL', qty: 100, asset_class: 'us_equity')
      create(:position, agent: other_agent, ticker: 'AAPL', qty: 50, asset_class: 'us_equity')

      expect {
        described_class.new.perform
      }.to have_enqueued_job(TickerMetricsRefreshJob).exactly(1).times
    end

    it 'does nothing when no equity positions exist' do
      expect {
        described_class.new.perform
      }.not_to have_enqueued_job(TickerMetricsRefreshJob)
    end

    it 'includes watchlist equities even when not currently held' do
      create(:watchlist, agent: agent, ticker: 'JNJ')

      expect {
        described_class.new.perform
      }.to have_enqueued_job(TickerMetricsRefreshJob).exactly(1).times
    end

    it 'deduplicates overlap between positions and watchlists' do
      create(:position, agent: agent, ticker: 'CVX', qty: 20, asset_class: 'us_equity')
      create(:watchlist, agent: agent, ticker: 'CVX')

      expect {
        described_class.new.perform
      }.to have_enqueued_job(TickerMetricsRefreshJob).exactly(1).times
    end
  end
end
