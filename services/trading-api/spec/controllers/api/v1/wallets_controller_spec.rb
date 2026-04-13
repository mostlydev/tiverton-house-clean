# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::WalletsController, type: :controller do
  describe 'GET #index in ledger mode' do
    let!(:agent) { create(:agent) }

    before do
      allow(controller).to receive(:require_local_request).and_return(true)
      allow(LedgerMigration).to receive(:read_from_ledger?).and_return(true)
    end

    context 'with ledger data' do
      before do
        # Create position lots (ledger source of truth for invested) - bootstrap to skip fill validation
        create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 10.0, cost_basis_per_share: 150.0, total_cost_basis: 1500.0)
        create(:position_lot, :bootstrap, agent: agent, ticker: 'MSFT', qty: 5.0, cost_basis_per_share: 200.0, total_cost_basis: 1000.0)

        # Create ledger entries for cash
        txn = create(:ledger_transaction, agent: agent, asset: 'USD')
        create(:ledger_entry, ledger_transaction: txn, agent: agent, account_code: "agent:#{agent.agent_id}:cash", asset: 'USD', amount: 15000.0)
      end

      it 'returns wallets with invested calculated from position lots' do
        get :index, format: :json

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)

        expect(json['source']).to eq('ledger')

        wallet = json['wallets'].find { |w| w['agent_id'] == agent.agent_id }
        expect(wallet).not_to be_nil
        expect(wallet['cash'].to_f).to eq(15000.0)
        expect(wallet['invested'].to_f).to eq(2500.0) # Sum of position lots
        expect(wallet['total_value'].to_f).to eq(17500.0)
        expect(wallet['wallet_size'].to_f).to eq(agent.wallet.wallet_size.to_f)
      end

      it 'excludes closed lots from invested calculation' do
        # Add a closed lot that should not count
        create(:position_lot, :closed, :bootstrap, agent: agent, ticker: 'TSLA', qty: 2.0, cost_basis_per_share: 300.0)

        get :index, format: :json

        json = JSON.parse(response.body)
        wallet = json['wallets'].find { |w| w['agent_id'] == agent.agent_id }

        # Still 2500, not 3100
        expect(wallet['invested'].to_f).to eq(2500.0)
      end

      it 'handles agents with no positions' do
        empty_agent = create(:agent)
        txn = create(:ledger_transaction, agent: empty_agent, asset: 'USD')
        create(:ledger_entry, ledger_transaction: txn, agent: empty_agent, account_code: "agent:#{empty_agent.agent_id}:cash", asset: 'USD', amount: 20000.0)

        get :index, format: :json

        json = JSON.parse(response.body)
        wallet = json['wallets'].find { |w| w['agent_id'] == empty_agent.agent_id }

        expect(wallet['cash'].to_f).to eq(20000.0)
        expect(wallet['invested'].to_f).to eq(0.0)
        expect(wallet['total_value'].to_f).to eq(20000.0)
      end
    end

    context 'with no ledger data' do
      it 'returns wallets with zero cash when no ledger entries exist' do
        # No position lots, no ledger entries - but agent still shows with zero cash
        get :index, format: :json

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)

        # Agent shows with zero cash (no ledger entries)
        wallet = json['wallets'].find { |w| w['agent_id'] == agent.agent_id }
        expect(wallet).not_to be_nil
        expect(wallet['cash'].to_f).to eq(0.0)
        expect(wallet['invested'].to_f).to eq(0.0)
      end
    end
  end

  describe 'GET #show in ledger mode' do
    let!(:agent) { create(:agent) }

    before do
      allow(controller).to receive(:require_local_request).and_return(true)
      allow(LedgerMigration).to receive(:read_from_ledger?).and_return(true)
    end

    it 'returns wallet with invested from position lots' do
      create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 10.0, cost_basis_per_share: 150.0, total_cost_basis: 1500.0)
      txn = create(:ledger_transaction, agent: agent, asset: 'USD')
      create(:ledger_entry, ledger_transaction: txn, agent: agent, account_code: "agent:#{agent.agent_id}:cash", asset: 'USD', amount: 5000.0)

      get :show, params: { id: agent.agent_id }, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)

      expect(json['agent_id']).to eq(agent.agent_id)
      expect(json['cash'].to_f).to eq(5000.0)
      expect(json['invested'].to_f).to eq(1500.0)
      expect(json['total_value'].to_f).to eq(6500.0)
      expect(json['source']).to eq('ledger')
    end

    it 'supports lookup by wallet id' do
      create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 5.0, cost_basis_per_share: 100.0, total_cost_basis: 500.0)
      txn = create(:ledger_transaction, agent: agent, asset: 'USD')
      create(:ledger_entry, ledger_transaction: txn, agent: agent, account_code: "agent:#{agent.agent_id}:cash", asset: 'USD', amount: 1000.0)

      get :show, params: { id: agent.wallet.id }, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)

      expect(json['agent_id']).to eq(agent.agent_id)
    end

    it 'returns 404 for non-existent agent' do
      get :show, params: { id: 'nonexistent' }, format: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET #index in legacy mode' do
    let!(:agent) { create(:agent) }

    before do
      # Set up wallet with investments
      agent.wallet.update!(cash: 10000.0, invested: 10000.0)
      allow(controller).to receive(:require_local_request).and_return(true)
      allow(LedgerMigration).to receive(:read_from_ledger?).and_return(false)
    end

    it 'returns wallets from legacy Wallet table' do
      get :index, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)

      expect(json['source']).to eq('legacy')

      wallet = json['wallets'].find { |w| w['agent_id'] == agent.agent_id }
      expect(wallet['cash'].to_f).to eq(10000.0)
      expect(wallet['invested'].to_f).to eq(10000.0)
    end
  end

  describe 'PATCH #update' do
    let!(:agent) { create(:agent) }

    before do
      allow(controller).to receive(:require_local_request).and_return(true)
    end

    it 'updates wallet attributes' do
      patch :update, params: { id: agent.wallet.id, wallet: { wallet_size: 30000.0 } }, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)

      expect(json['wallet_size'].to_f).to eq(30000.0)
      agent.wallet.reload
      expect(agent.wallet.wallet_size.to_f).to eq(30000.0)
    end

    it 'returns error for invalid attributes' do
      allow_any_instance_of(Wallet).to receive(:update).and_return(false)
      allow_any_instance_of(Wallet).to receive(:errors).and_return(double(full_messages: ['Invalid']))

      patch :update, params: { id: agent.wallet.id, wallet: { cash: 'invalid' } }, format: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

end
