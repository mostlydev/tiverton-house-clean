# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::DeskRiskContext', type: :request do
  before do
    allow(LedgerMigration).to receive(:read_from_ledger?).and_return(false)
    allow(AppConfig).to receive(:public_web_hosts).and_return(["www.tivertonhouse.com"])
    allow(AppConfig).to receive(:trading_api_internal_token).and_return("internal-token")
    allow(AppConfig).to receive(:trading_api_agent_tokens).and_return("tiverton" => "tiverton-token")
  end

  it 'returns desk-wide risk context for a known agent' do
    tiverton = create(:agent,
                      agent_id: 'tiverton',
                      name: 'Tiverton',
                      role: 'infrastructure',
                      style: 'risk')
    logan = create(:agent,
                   agent_id: 'logan',
                   name: 'Logan',
                   role: 'trader',
                   style: 'value')
    logan.wallet.update!(wallet_size: 25_000.0, cash: 12_000.0, invested: 13_000.0)
    create(:position, agent: logan, ticker: 'KO', qty: 66, avg_entry_price: 74.8, current_value: 5_067.0)

    get '/api/v1/desk_risk_context/tiverton', headers: { "Authorization" => "Bearer tiverton-token" }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['requested_by']['agent_id']).to eq('tiverton')
    expect(body['trader_wallets'].map { |wallet| wallet['agent_id'] }).to eq(['logan'])
    expect(body['open_positions'].map { |position| position['ticker'] }).to eq(['KO'])
  end

  it 'returns not found for an unknown agent' do
    get '/api/v1/desk_risk_context/not-a-real-agent', headers: { "Authorization" => "Bearer tiverton-token" }

    expect(response).to have_http_status(:not_found)
    body = JSON.parse(response.body)
    expect(body['error']).to eq('Agent not found')
  end

  it 'rejects non-coordinator principals' do
    create(:agent, agent_id: 'weston', role: 'trader')
    allow(AppConfig).to receive(:trading_api_agent_tokens).and_return("weston" => "weston-token")

    get '/api/v1/desk_risk_context/weston', headers: { "Authorization" => "Bearer weston-token" }

    expect(response).to have_http_status(:forbidden)
  end
end
