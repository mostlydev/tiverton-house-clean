# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::PositionsController, type: :controller do
  describe 'GET #index in ledger mode' do
    let!(:agent) { create(:agent) }
    let!(:price_sample) { create(:price_sample, ticker: 'AAPL', price: 160.0) }
    let(:mock_broker) { instance_double(Alpaca::BrokerService) }

    before do
      allow(controller).to receive(:require_local_request).and_return(true)
      allow(LedgerMigration).to receive(:read_from_ledger?).and_return(true)
      allow(Alpaca::BrokerService).to receive(:new).and_return(mock_broker)
    end

    context 'with ledger positions' do
      before do
        # Create position lots (ledger source of truth) - bootstrap to skip fill validation
        create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 10.0, cost_basis_per_share: 150.0, total_cost_basis: 1500.0)
        create(:position_lot, :bootstrap, agent: agent, ticker: 'MSFT', qty: 5.0, cost_basis_per_share: 200.0, total_cost_basis: 1000.0)
      end

      it 'returns positions with calculated current values from price samples' do
        # MSFT has no price sample, so it will try to fetch from Alpaca
        allow(mock_broker).to receive(:get_quote)
          .with(ticker: 'MSFT', side: 'BUY', quiet: true)
          .and_return({ success: true, price: 210.0, last: 210.0 })

        get :index, format: :json

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)

        expect(json['source']).to eq('ledger')
        expect(json['positions'].size).to eq(2)

        aapl = json['positions'].find { |p| p['ticker'] == 'AAPL' }
        expect(aapl['qty']).to eq(10.0)
        expect(aapl['cost_basis']).to eq(1500.0)
        expect(aapl['avg_cost_per_share']).to eq(150.0)
        expect(aapl['current_price']).to eq(160.0)
        expect(aapl['current_value']).to eq(1600.0)
        expect(aapl['unrealized_pnl']).to eq(100.0)
        expect(aapl['unrealized_pnl_percentage']).to be_within(0.01).of(6.67)
      end

      it 'filters by agent_id' do
        other_agent = create(:agent)
        create(:position_lot, :bootstrap, agent: other_agent, ticker: 'TSLA', qty: 1.0, cost_basis_per_share: 100.0, total_cost_basis: 100.0)

        # MSFT has no price sample
        allow(mock_broker).to receive(:get_quote)
          .with(ticker: 'MSFT', side: 'BUY', quiet: true)
          .and_return({ success: true, price: 210.0, last: 210.0 })

        get :index, params: { agent_id: agent.agent_id }, format: :json

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)

        expect(json['positions'].size).to eq(2)
        tickers = json['positions'].map { |p| p['ticker'] }
        expect(tickers).to contain_exactly('AAPL', 'MSFT')
      end

      it 'handles positions without price samples' do
        # MSFT has no price sample, mock Alpaca returning no data
        allow(mock_broker).to receive(:get_quote)
          .with(ticker: 'MSFT', side: 'BUY', quiet: true)
          .and_return({ success: false, error: 'No quote' })

        get :index, format: :json

        json = JSON.parse(response.body)
        msft = json['positions'].find { |p| p['ticker'] == 'MSFT' }

        expect(msft['current_price']).to be_nil
        expect(msft['current_value']).to be_nil
        expect(msft['unrealized_pnl']).to be_nil
      end
    end

    context 'with no positions' do
      it 'returns empty array' do
        get :index, format: :json

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['positions']).to be_empty
      end
    end

    context 'with closed lots' do
      before do
        create(:position_lot, :closed, :bootstrap, agent: agent, ticker: 'AAPL', qty: 10.0, cost_basis_per_share: 150.0)
        create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 5.0, cost_basis_per_share: 160.0, total_cost_basis: 800.0)
      end

      it 'excludes closed lots from position calculation' do
        get :index, params: { agent_id: agent.agent_id }, format: :json

        json = JSON.parse(response.body)
        expect(json['positions'].size).to eq(1)

        aapl = json['positions'].first
        expect(aapl['qty']).to eq(5.0) # Only open lot
        expect(aapl['cost_basis']).to eq(800.0)
      end
    end
  end

  describe 'GET #index in legacy mode' do
    let!(:agent) { create(:agent) }

    before do
      allow(controller).to receive(:require_local_request).and_return(true)
      allow(LedgerMigration).to receive(:read_from_ledger?).and_return(false)
    end

    it 'returns positions from legacy Position table' do
      position = create(:position, agent: agent, ticker: 'AAPL', qty: 10, avg_entry_price: 150.0, current_value: 1600.0)

      get :index, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)

      expect(json['source']).to eq('legacy')
      expect(json['positions'].size).to eq(1)
      expect(json['positions'].first['ticker']).to eq('AAPL')
    end
  end

  describe 'POST #revalue' do
    let!(:agent) { create(:agent) }

    before do
      allow(controller).to receive(:require_local_request).and_return(true)
    end

    it 'updates position current_values from provided prices' do
      position = create(:position, agent: agent, ticker: 'AAPL', qty: 10, current_value: 1500.0)

      post :revalue, params: { prices: { 'AAPL' => 160.0 } }, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)

      expect(json['updated']).to eq(1)
      position.reload
      expect(position.current_value.to_f).to eq(1600.0)
    end
  end

  describe 'POST #cleanup_dust' do
    let!(:agent) { create(:agent) }

    before do
      allow(controller).to receive(:require_local_request).and_return(true)
    end

    it 'removes dust positions in dry run mode' do
      create(:position, agent: agent, ticker: 'AAPL', qty: 10, current_value: 1500.0)
      dust = create(:position, agent: agent, ticker: 'DUST', qty: 0.005, current_value: 0.5)

      post :cleanup_dust, params: { threshold_qty: 0.01, threshold_value: 1.0, dry_run: 'true' }, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)

      expect(json['dry_run']).to be true
      expect(json['would_delete']).to eq(1)
      expect(Position.count).to eq(2) # Not actually deleted
    end
  end
end
