# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TradersController, type: :controller do
  render_views

  describe 'GET #show' do
    it 'uses live-marked position value when calculating the trader total in legacy mode' do
      agent = create(:agent, agent_id: 'weston', name: 'Weston', role: 'trader', style: 'momentum')
      agent.wallet.update!(wallet_size: 25_000.0, cash: 10_000.0, invested: 9_000.0)
      create(:position, agent: agent, ticker: 'AAPL', qty: 10, avg_entry_price: 900.0, current_value: 9_000.0)
      create(:price_sample, ticker: 'AAPL', price: 1_000.0)

      get :show, params: { name: 'weston' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('>$20,000.00<')
      expect(response.body).to include('-$5,000.00')
      expect(response.body).to include('vs $25,000 Start')
      expect(response.body).not_to include('>$19,000.00<')
    end

    it 'renders the public description, focus, and watchlist' do
      agent = create(:agent, agent_id: 'weston', name: 'Weston', role: 'trader', style: 'momentum')
      create(:watchlist, agent: agent, ticker: 'NVDA')
      create(:watchlist, agent: agent, ticker: 'TSLA')

      get :show, params: { name: 'weston' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Description')
      expect(response.body).to include('Focus')
      expect(response.body).to include('Watchlist')
      expect(response.body).to include('NVDA')
      expect(response.body).to include('TSLA')
      expect(response.body).to include('Fast-moving momentum trader')
      expect(response.body).to include('Momentum breakouts')
    end

    it 'shows realized P&L on sell rows using closed-lot attribution' do
      agent = create(:agent, agent_id: 'weston', name: 'Weston', role: 'trader', style: 'momentum')
      trade = create(:trade, :filled, :sell, agent: agent, ticker: 'NVDA', qty_filled: 5, avg_fill_price: 115.0, filled_value: 575.0)
      broker_order = create(:broker_order, trade: trade, agent: agent, ticker: 'NVDA', side: 'sell')
      fill = create(:broker_fill, :sell, broker_order: broker_order, trade: trade, agent: agent, ticker: 'NVDA', qty: 5, price: 115.0, value: 575.0)
      create(:position_lot, :closed, agent: agent, ticker: 'NVDA', qty: 5, cost_basis_per_share: 100.0, total_cost_basis: 500.0, close_source_id: fill.id, realized_pnl: 75.0)

      get :show, params: { name: 'weston' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('>P&amp;L<')
      expect(response.body.scan(/\+\$75\.00/).length).to be >= 2
    end

    it 'hides non-public profiles from the public page' do
      create(:agent, agent_id: 'dundas', name: 'Dundas', role: 'trader', style: 'event')

      get :show, params: { name: 'dundas' }

      expect(response).to have_http_status(:not_found)
    end

    it 'does not assign a fake funded baseline to unfunded agents' do
      agent = create(:agent, agent_id: 'tiverton', name: 'Tiverton', role: 'infrastructure', style: 'risk')
      agent.wallet.update!(wallet_size: 0.0, cash: 0.0, invested: 0.0)

      get :show, params: { name: 'tiverton' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('vs $0 Start')
      expect(response.body).not_to include('-$25,000.00')
    end
  end

  describe 'GET #ledger' do
    it 'uses the same live-marked total and dynamic starting label as the profile page' do
      agent = create(:agent, agent_id: 'weston', name: 'Weston', role: 'trader', style: 'momentum')
      agent.wallet.update!(wallet_size: 25_000.0, cash: 10_000.0, invested: 9_000.0)
      create(:position, agent: agent, ticker: 'AAPL', qty: 10, avg_entry_price: 900.0, current_value: 9_000.0)
      create(:price_sample, ticker: 'AAPL', price: 1_000.0)

      get :ledger, params: { name: 'weston' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Current Total')
      expect(response.body).to include('>$20,000.00<')
      expect(response.body).to include('vs $25,000 Start')
      expect(response.body).not_to include('>$19,000.00<')
    end

    it 'renders the public watchlist summary on the ledger page' do
      agent = create(:agent, agent_id: 'weston', name: 'Weston', role: 'trader', style: 'momentum')
      create(:watchlist, agent: agent, ticker: 'AAPL')

      get :ledger, params: { name: 'weston' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Watchlist')
      expect(response.body).to include('AAPL')
    end

    it 'shows realized P&L in the ledger trade history for sell fills' do
      agent = create(:agent, agent_id: 'weston', name: 'Weston', role: 'trader', style: 'momentum')
      trade = create(:trade, :filled, :sell, agent: agent, ticker: 'AAPL', qty_filled: 4, avg_fill_price: 130.0, filled_value: 520.0)
      broker_order = create(:broker_order, trade: trade, agent: agent, ticker: 'AAPL', side: 'sell')
      fill = create(:broker_fill, :sell, broker_order: broker_order, trade: trade, agent: agent, ticker: 'AAPL', qty: 4, price: 130.0, value: 520.0)
      create(:position_lot, :closed, agent: agent, ticker: 'AAPL', qty: 4, cost_basis_per_share: 120.0, total_cost_basis: 480.0, close_source_id: fill.id, realized_pnl: 40.0)

      get :ledger, params: { name: 'weston' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('>P&amp;L<')
      expect(response.body.scan(/\+\$40\.00/).length).to be >= 2
    end
  end
end
