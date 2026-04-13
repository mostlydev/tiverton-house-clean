# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DashboardController, type: :controller do
  render_views

  let(:mock_broker) { instance_double(Alpaca::BrokerService) }

  before do
    allow(controller).to receive(:require_local_request).and_return(true)
    allow(Alpaca::BrokerService).to receive(:new).and_return(mock_broker)
    allow(mock_broker).to receive(:get_quote).and_return({ success: false, error: 'No quote' })
  end

  describe 'GET #positions (Turbo Frame)' do
    let!(:agent) { create(:agent, agent_id: 'boulton', name: 'Boulton') }

    context 'in ledger mode' do
      before do
        allow(LedgerMigration).to receive(:read_from_ledger?).and_return(true)
      end

      it 'renders ledger positions in the positions frame' do
        create(:position_lot, :bootstrap, agent: agent, ticker: 'HIMS', qty: 16.0, cost_basis_per_share: 18.03, total_cost_basis: 288.48)

        get :positions

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq('text/html')
        expect(response.body).to include('turbo-frame')
        expect(response.body).to include('positions')
        expect(response.body).to include('HIMS')
        expect(response.body).to include('Boulton')
      end
    end

    context 'in legacy mode' do
      before do
        allow(LedgerMigration).to receive(:read_from_ledger?).and_return(false)
      end

      it 'renders legacy positions in the positions frame' do
        # In legacy mode, positions use agent_id (the integer ID), not agent.agent_id (the string)
        create(:position, agent: agent, ticker: 'AAPL', qty: 10, avg_entry_price: 150.0, current_value: 1600.0)

        get :positions

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq('text/html')
        expect(response.body).to include('AAPL')
        expect(response.body).to include('Boulton')
      end

      it 'reprices legacy positions from the latest price sample for dashboard display' do
        create(:position, agent: agent, ticker: 'AAPL', qty: 10, avg_entry_price: 150.0, current_value: 1500.0)
        create(:price_sample, ticker: 'AAPL', price: 160.0)

        get :positions

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('$1,600.00')
        expect(response.body).to include('$100.00')
        expect(response.body).to include('+6.67%')
      end
    end
  end

  describe 'GET #news_ticker' do
    it 'renders the filtered news ticker partial' do
      NewsArticle.create!(
        headline: 'NVDA rallies on earnings beat',
        source: 'alpaca',
        summary: 'Strong quarter.',
        content: 'Strong quarter.',
        url: 'https://example.com/nvda',
        published_at: Time.current,
        fetched_at: Time.current,
        external_id: 'news-1'
      )

      get :news_ticker

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/html')
      expect(response.body).to include('NVDA rallies on earnings beat')
    end
  end

  describe 'GET #index' do
    let!(:agent) { create(:agent, :gerrard, name: 'Gerrard') }

    before do
      allow(Dashboard::MarketStatusService).to receive(:current).and_return({ status: 'OPEN' })
      allow(Dashboard::MarketStatusService).to receive(:status_for_trade).and_return('market-hours')
      allow(Dashboard::SystemHealthService).to receive(:check).and_return({})
      allow(Dashboard::PortfolioService).to receive(:summary).and_return(
        equity: 25_000.0,
        cash: 25_000.0,
        buying_power: 25_000.0,
        pnl: 0.0,
        pnl_percent: 0.0
      )
      allow(Dashboard::TradingFloorService).to receive(:recent_feed).and_return({ available: false, items: [] })
    end

    it 'renders qty and fill value for filled quantity-based trades' do
      create(
        :trade,
        :filled,
        :sell,
        agent: agent,
        ticker: 'EQT',
        qty_requested: 74.360499702,
        qty_filled: 74.360499702,
        amount_requested: nil,
        avg_fill_price: 63.4,
        filled_value: 4714.46,
        thesis: 'STOP_LOSS_AUTO: price $63.42 hit stop $63.50. SELL_ALL.'
      )

      get :index

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Qty')
      expect(response.body).to include('Notional / Fill Value')
      expect(response.body).to include('74.3605')
      expect(response.body).to include('$4,714.46')
    end

    it 'shows broker snapshot freshness and preserves live broker cash in the portfolio bar' do
      create(:position, agent: agent, ticker: 'AAPL', qty: 10, avg_entry_price: 100.0, current_value: 1000.0)
      create(:price_sample, ticker: 'AAPL', price: 120.0)

      allow(Dashboard::PortfolioService).to receive(:summary).and_return(
        equity: 5000.0,
        cash: 3800.0,
        buying_power: 10_000.0,
        source: 'alpaca_live',
        wallet_last_synced_at: 2.minutes.ago,
        data_timestamp_label: 'Broker Snapshot'
      )

      get :index

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('$3,800.00')
      expect(response.body).to include('Broker Snapshot')
      expect(response.body).to include('+$200.00')
    end
  end
end
