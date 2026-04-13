# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MarketContextService, type: :service do
  let!(:agent) { create(:agent, agent_id: 'boulton', name: 'Boulton') }
  let(:mock_broker) { instance_double(Alpaca::BrokerService) }

  before do
    allow(Alpaca::BrokerService).to receive(:new).and_return(mock_broker)
    allow(mock_broker).to receive(:get_quote).and_return({ success: false, error: 'No quote' })
  end

  describe '#call in ledger mode' do
    before do
      allow(LedgerMigration).to receive(:read_from_ledger?).and_return(true)
    end

    it 'returns positions from ledger' do
      create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 10.0, cost_basis_per_share: 150.0, total_cost_basis: 1500.0)
      create(:price_sample, ticker: 'AAPL', price: 160.0)

      service = MarketContextService.new(agent)
      context = service.call

      expect(context[:positions]).not_to be_empty
      aapl = context[:positions].find { |p| p[:ticker] == 'AAPL' }
      expect(aapl).not_to be_nil
      expect(aapl[:qty]).to eq(10.0)
      expect(aapl[:avg_entry_price]).to eq(150.0)
      expect(aapl[:current_value]).to eq(1600.0) # 10 * 160
      expect(aapl[:unrealized_pl]).to eq(100.0) # 1600 - 1500
    end

    it 'calculates portfolio_value from ledger positions' do
      create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 10.0, cost_basis_per_share: 150.0, total_cost_basis: 1500.0)
      create(:position_lot, :bootstrap, agent: agent, ticker: 'MSFT', qty: 5.0, cost_basis_per_share: 200.0, total_cost_basis: 1000.0)
      create(:price_sample, ticker: 'AAPL', price: 160.0)
      create(:price_sample, ticker: 'MSFT', price: 210.0)

      service = MarketContextService.new(agent)
      context = service.call

      # AAPL: 10 * 160 = 1600, MSFT: 5 * 210 = 1050, Total = 2650
      expect(context[:portfolio_value]).to eq(2650.0)
    end

    it 'calculates total_cost_basis from ledger positions' do
      create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 10.0, cost_basis_per_share: 150.0, total_cost_basis: 1500.0)
      create(:position_lot, :bootstrap, agent: agent, ticker: 'MSFT', qty: 5.0, cost_basis_per_share: 200.0, total_cost_basis: 1000.0)

      service = MarketContextService.new(agent)
      context = service.call

      expect(context[:total_cost_basis]).to eq(2500.0) # 1500 + 1000
    end

    it 'excludes closed lots from positions' do
      create(:position_lot, :closed, :bootstrap, agent: agent, ticker: 'AAPL', qty: 10.0, cost_basis_per_share: 150.0)
      create(:position_lot, :bootstrap, agent: agent, ticker: 'MSFT', qty: 5.0, cost_basis_per_share: 200.0, total_cost_basis: 1000.0)

      service = MarketContextService.new(agent)
      context = service.call

      expect(context[:positions].size).to eq(1)
      expect(context[:positions].first[:ticker]).to eq('MSFT')
    end

    it 'returns wallet data from ledger' do
      create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 10.0, cost_basis_per_share: 150.0, total_cost_basis: 1500.0)
      txn = create(:ledger_transaction, agent: agent, asset: 'USD')
      create(:ledger_entry, ledger_transaction: txn, agent: agent, account_code: "agent:#{agent.agent_id}:cash", asset: 'USD', amount: 5000.0)

      service = MarketContextService.new(agent)
      context = service.call

      expect(context[:wallet][:cash]).to eq(5000.0)
      expect(context[:wallet][:invested]).to eq(1500.0)
      expect(context[:buying_power]).to eq(5000.0) # cash - locked_buy (0)
    end

    it 'includes price motion data for positions' do
      create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 10.0, cost_basis_per_share: 150.0, total_cost_basis: 1500.0)
      create(:price_sample, ticker: 'AAPL', price: 160.0)

      service = MarketContextService.new(agent)
      context = service.call

      expect(context[:price_motion][:positions]).not_to be_empty
      expect(context[:price_motion][:positions].first[:ticker]).to eq('AAPL')
      expect(context[:price_motion][:positions].first[:last]).to eq(160.0)
    end

    it 'returns empty positions when no ledger data' do
      service = MarketContextService.new(agent)
      context = service.call

      expect(context[:positions]).to be_empty
      expect(context[:portfolio_value]).to eq(0.0)
      expect(context[:total_cost_basis]).to eq(0.0)
    end
  end

  describe '#call in legacy mode' do
    before do
      allow(LedgerMigration).to receive(:read_from_ledger?).and_return(false)
    end

    it 'returns positions from legacy Position table' do
      create(:position, agent: agent, ticker: 'AAPL', qty: 10, avg_entry_price: 150.0, current_value: 1600.0)

      service = MarketContextService.new(agent)
      context = service.call

      expect(context[:positions]).not_to be_empty
      expect(context[:positions].first[:ticker]).to eq('AAPL')
      expect(context[:positions].first[:qty]).to eq(10)
    end

    it 'uses the agent wallet cash for buying power even when a broker snapshot exists' do
      agent.wallet.update!(wallet_size: 25_000.0, cash: 25_000.0, invested: 0.0)
      BrokerAccountSnapshot.create!(
        broker: 'alpaca',
        cash: 37_476.97,
        buying_power: 312_859.09,
        equity: 98_490.28,
        portfolio_value: 98_490.28,
        fetched_at: Time.current,
        raw_account: {}
      )

      service = MarketContextService.new(agent)
      context = service.call

      expect(context[:wallet][:cash]).to eq(25_000.0)
      expect(context[:buying_power]).to eq(25_000.0)
      expect(context[:locked][:available_cash]).to eq(25_000.0)
      expect(context[:locked][:account_buying_power]).to be_nil
    end

    it 'adds relative strength versus SPY and QQQ to price motion' do
      create(:position, agent: agent, ticker: 'AAPL', qty: 10, avg_entry_price: 100.0, current_value: 1100.0)
      create(:price_sample, ticker: 'AAPL', price: 100.0, sampled_at: 16.minutes.ago, sample_minute: 16.minutes.ago.strftime('%Y-%m-%d %H:%M:00'))
      create(:price_sample, ticker: 'AAPL', price: 110.0, sampled_at: 1.minute.ago, sample_minute: 1.minute.ago.strftime('%Y-%m-%d %H:%M:00'))
      create(:price_sample, ticker: 'SPY', price: 100.0, sampled_at: 16.minutes.ago, sample_minute: 16.minutes.ago.strftime('%Y-%m-%d %H:%M:00'))
      create(:price_sample, ticker: 'SPY', price: 105.0, sampled_at: 1.minute.ago, sample_minute: 1.minute.ago.strftime('%Y-%m-%d %H:%M:00'))
      create(:price_sample, ticker: 'QQQ', price: 100.0, sampled_at: 16.minutes.ago, sample_minute: 16.minutes.ago.strftime('%Y-%m-%d %H:%M:00'))
      create(:price_sample, ticker: 'QQQ', price: 108.0, sampled_at: 1.minute.ago, sample_minute: 1.minute.ago.strftime('%Y-%m-%d %H:%M:00'))

      service = MarketContextService.new(agent)
      context = service.call
      snapshot = context[:price_motion][:positions].find { |row| row[:ticker] == 'AAPL' }

      aggregate_failures do
        expect(snapshot[:change_15m]).to eq(10.0)
        expect(snapshot[:rs_vs_spy_15m]).to eq(5.0)
        expect(snapshot[:rs_vs_qqq_15m]).to eq(2.0)
      end
    end
  end
end
