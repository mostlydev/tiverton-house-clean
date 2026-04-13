# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DeskRiskContextService, type: :service do
  let!(:tiverton) do
    create(:agent,
           agent_id: 'tiverton',
           name: 'Tiverton',
           role: 'infrastructure',
           style: 'risk')
  end

  let!(:logan) do
    create(:agent,
           agent_id: 'logan',
           name: 'Logan',
           role: 'trader',
           style: 'value')
  end

  let!(:gerrard) do
    create(:agent,
           agent_id: 'gerrard',
           name: 'Gerrard',
           role: 'trader',
           style: 'macro')
  end

  let!(:sentinel) do
    create(:agent,
           agent_id: 'sentinel',
           name: 'Sentinel',
           role: 'infrastructure',
           style: 'executor')
  end

  before do
    allow(LedgerMigration).to receive(:read_from_ledger?).and_return(false)

    tiverton.wallet.update!(wallet_size: 0.0, cash: 0.0, invested: 0.0)
    logan.wallet.update!(wallet_size: 25_000.0, cash: 12_000.0, invested: 13_000.0)
    gerrard.wallet.update!(wallet_size: 25_000.0, cash: 20_000.0, invested: 5_000.0)
    sentinel.wallet.update!(wallet_size: 0.0, cash: 0.0, invested: 0.0)
  end

  it 'returns desk-wide trader wallets and positions, excluding infrastructure wallets' do
    create(:position, agent: logan, ticker: 'KO', qty: 66, avg_entry_price: 74.8, current_value: 5_067.0)
    create(:position, :small, agent: gerrard, ticker: 'EQT', avg_entry_price: 67.24, current_value: 5_040.9)

    context = described_class.new(tiverton).call

    expect(context[:requested_by][:agent_id]).to eq('tiverton')
    expect(context[:trader_wallets].map { |wallet| wallet[:agent_id] }).to eq(%w[gerrard logan])
    expect(context[:open_positions].map { |position| position[:ticker] }).to contain_exactly('EQT', 'KO')
    expect(context[:exposure_summary][:trader_count]).to eq(2)
    expect(context[:exposure_summary][:total_wallet_size]).to eq(50_000.0)
    expect(context[:exposure_summary][:portfolio_value]).to eq(10_107.9)
    expect(context[:exposure_summary][:buying_power]).to eq(32_000.0)
  end

  it 'includes desk-wide pending orders and recent fills' do
    create(:trade, :approved, agent: logan, ticker: 'BX', qty_requested: 25)
    create(:trade, :filled, agent: gerrard, ticker: 'EQT', qty_filled: 10, avg_fill_price: 67.0, filled_value: 670.0)

    context = described_class.new(tiverton).call

    expect(context[:pending_orders].map { |trade| trade[:ticker] }).to eq(['BX'])
    expect(context[:recent_fills].map { |trade| trade[:ticker] }).to eq(['EQT'])
  end

  it 'emits concentration alerts for oversized positions' do
    create(:position, agent: logan, ticker: 'QCOM', qty: 22, avg_entry_price: 131.4, current_value: 7_600.0)

    context = described_class.new(tiverton).call

    expect(context[:risk_alerts]).not_to be_empty
    alert = context[:risk_alerts].first
    expect(alert[:type]).to eq('position_concentration')
    expect(alert[:agent_id]).to eq('logan')
    expect(alert[:ticker]).to eq('QCOM')
    expect(alert[:concentration_pct]).to be > 25.0
  end
end
