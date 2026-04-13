# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::TradesController, type: :controller do
  describe 'POST #fill' do
    let!(:agent) { create(:agent) }

    before do
      allow(controller).to receive(:require_local_request).and_return(true)
      allow(AppConfig).to receive(:trading_api_internal_token).and_return("internal-token")
      allow(AppConfig).to receive(:trading_api_agent_tokens).and_return({})
      request.headers["Authorization"] = "Bearer internal-token"
    end

    it 'processes a partial fill and updates position and wallet via fill processor' do
      trade = create(
        :trade,
        :executing,
        agent: agent,
        ticker: 'AAPL',
        side: 'BUY',
        qty_requested: 10,
        qty_filled: nil,
        avg_fill_price: nil,
        filled_value: nil
      )

      post :fill, params: { id: trade.trade_id, qty_filled: 4, avg_fill_price: 100.0, final: false }, format: :json

      expect(response).to have_http_status(:ok)

      trade.reload
      wallet = agent.wallet.reload
      position = Position.find_by(agent: agent, ticker: 'AAPL')

      expect(trade.status).to eq('PARTIALLY_FILLED')
      expect(trade.qty_filled.to_f).to eq(4.0)
      expect(trade.avg_fill_price.to_f).to eq(100.0)
      expect(trade.filled_value.to_f).to eq(400.0)

      expect(position).not_to be_nil
      expect(position.qty.to_f).to eq(4.0)
      expect(position.avg_entry_price.to_f).to eq(100.0)
      expect(wallet.cash.to_f).to eq(19_600.0)
      expect(wallet.invested.to_f).to eq(400.0)
    end

    it 'accepts filled_value without avg_fill_price and derives avg_fill_price' do
      trade = create(
        :trade,
        :executing,
        agent: agent,
        ticker: 'MSFT',
        side: 'BUY',
        qty_requested: 5,
        qty_filled: nil,
        avg_fill_price: nil,
        filled_value: nil
      )

      post :fill, params: { id: trade.trade_id, qty_filled: 5, filled_value: 1500.0, final: true }, format: :json

      expect(response).to have_http_status(:ok)

      trade.reload
      expect(trade.status).to eq('FILLED')
      expect(trade.avg_fill_price.to_f).to eq(300.0)
      expect(trade.filled_value.to_f).to eq(1500.0)
    end

    it 'rejects fills without both avg_fill_price and filled_value' do
      trade = create(:trade, :executing, agent: agent, qty_requested: 10)

      post :fill, params: { id: trade.trade_id, qty_filled: 10 }, format: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to eq('avg_fill_price or filled_value is required')

      trade.reload
      expect(trade.status).to eq('EXECUTING')
      expect(trade.qty_filled).to be_nil
      expect(trade.avg_fill_price).to be_nil
      expect(trade.filled_value).to be_nil
    end
  end
end
