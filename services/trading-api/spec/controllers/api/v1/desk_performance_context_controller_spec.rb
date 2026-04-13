# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::DeskPerformanceContextController, type: :controller do
  before do
    allow(controller).to receive(:require_local_request).and_return(true)
    Rails.cache.clear
  end

  describe 'GET #show' do
    it 'returns the desk summary for the requesting trader principal' do
      agent = create(:agent, agent_id: 'weston', name: 'Weston', role: 'trader', status: 'active')
      agent.wallet.update!(wallet_size: 25_000.0, cash: 10_000.0, invested: 1_300.0)
      create(:position, agent: agent, ticker: 'NVDA', qty: 10, avg_entry_price: 100.0, current_value: 1_300.0)
      create(:position_lot, :closed, agent: agent, ticker: 'NVDA', realized_pnl: 100.0)

      allow(controller).to receive(:current_api_principal).and_return(
        ApplicationController::ApiPrincipal.new(id: agent.agent_id, type: :agent)
      )

      get :show, params: { agent_id: agent.agent_id }, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.dig('desk', 'funded_trader_count')).to eq(1)
      expect(json.fetch('traders').first.fetch('agent_id')).to eq('weston')
    end

    it 'rejects mismatched agent principals' do
      requested = create(:agent, agent_id: 'weston', name: 'Weston', role: 'trader', status: 'active')
      caller = create(:agent, agent_id: 'logan', name: 'Logan', role: 'trader', status: 'active')

      allow(controller).to receive(:current_api_principal).and_return(
        ApplicationController::ApiPrincipal.new(id: caller.agent_id, type: :agent)
      )

      get :show, params: { agent_id: requested.agent_id }, format: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'allows coordinator principals to fetch the desk summary' do
      agent = create(:agent, agent_id: 'weston', name: 'Weston', role: 'trader', status: 'active')
      allow(controller).to receive(:current_api_principal).and_return(
        ApplicationController::ApiPrincipal.new(id: 'tiverton', type: :coordinator)
      )

      get :show, params: { agent_id: agent.agent_id }, format: :json

      expect(response).to have_http_status(:ok)
    end
  end
end
