# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::OperationsController, type: :controller do
  before do
    allow(controller).to receive(:require_local_request).and_return(true)
    allow(controller).to receive(:require_coordinator_or_internal_api_principal!).and_return(true)
  end

  describe 'POST #market_data_backfill' do
    it 'queues a manual market data backfill job' do
      allow(MarketDataBackfillJob).to receive(:perform_later).and_return(instance_double(MarketDataBackfillJob, job_id: 'job-123'))

      post :market_data_backfill, params: { days: 20, tickers: 'aapl, spy' }, format: :json

      expect(response).to have_http_status(:accepted)
      expect(MarketDataBackfillJob).to have_received(:perform_later).with(days: 20, tickers: %w[AAPL SPY])

      body = JSON.parse(response.body)
      expect(body['queued']).to eq(true)
      expect(body['job_id']).to eq('job-123')
    end
  end

  describe 'POST #dividend_snapshot_refresh' do
    it 'queues a manual dividend snapshot refresh job' do
      allow(DividendSnapshotRefreshJob).to receive(:perform_later).and_return(instance_double(DividendSnapshotRefreshJob, job_id: 'job-456'))

      post :dividend_snapshot_refresh, params: { tickers: 'cvx, jnj' }, format: :json

      expect(response).to have_http_status(:accepted)
      expect(DividendSnapshotRefreshJob).to have_received(:perform_later).with(tickers: %w[CVX JNJ])

      body = JSON.parse(response.body)
      expect(body['queued']).to eq(true)
      expect(body['job_id']).to eq('job-456')
    end
  end

  describe 'POST #trader_context_prime' do
    it 'queues a combined trader-context prime job' do
      allow(TraderContextPrimeJob).to receive(:perform_later).and_return(instance_double(TraderContextPrimeJob, job_id: 'job-789'))

      post :trader_context_prime, params: { days: 15, tickers: 'cvx, jnj' }, format: :json

      expect(response).to have_http_status(:accepted)
      expect(TraderContextPrimeJob).to have_received(:perform_later).with(days: 15, tickers: %w[CVX JNJ])

      body = JSON.parse(response.body)
      expect(body['queued']).to eq(true)
      expect(body['job_id']).to eq('job-789')
    end
  end
end
