require 'rails_helper'

RSpec.describe Trades::PositionManagerService, type: :service do
  let(:agent) { create(:agent, :westin) }
  let(:wallet) { agent.wallet }
  let(:manager) { described_class.new(trade) }

  before do
    allow(LedgerMigration).to receive(:block_legacy_write?).and_return(false)
  end

  describe '#apply_delta' do
    context 'when BUY creates new position' do
      let(:trade) do
        create(:trade, :filled, agent: agent, ticker: 'TSLA', side: 'BUY',
               qty_filled: 50, avg_fill_price: 250.0, filled_value: 12500.0)
      end

      let(:delta) do
        { delta_qty: 50, delta_price: 250.0, delta_value: 12500.0 }
      end

      it 'creates new position with correct values' do
        expect {
          manager.apply_delta(delta)
        }.to change { Position.count }.by(1)

        position = Position.find_by(agent: agent, ticker: 'TSLA')
        expect(position.qty).to eq(50)
        expect(position.avg_entry_price).to eq(250.0)
        expect(position.current_value).to eq(12500.0)
        expect(position.opened_at).to be_present
      end

      it 'updates wallet correctly' do
        initial_cash = wallet.cash
        initial_invested = wallet.invested

        manager.apply_delta(delta)

        wallet.reload
        expect(wallet.cash).to eq(initial_cash - 12500.0)
        expect(wallet.invested).to eq(initial_invested + 12500.0)
      end
    end

    context 'when BUY adds to existing position' do
      let!(:existing_position) do
        create(:position, :tsla, agent: agent, qty: 30, avg_entry_price: 240.0, current_value: 7200.0)
      end

      let(:trade) do
        create(:trade, :filled, agent: agent, ticker: 'TSLA', side: 'BUY',
               qty_filled: 20, avg_fill_price: 260.0, filled_value: 5200.0)
      end

      let(:delta) do
        { delta_qty: 20, delta_price: 260.0, delta_value: 5200.0 }
      end

      it 'does not create new position' do
        expect {
          manager.apply_delta(delta)
        }.not_to change { Position.count }
      end

      it 'calculates weighted average entry price (VWAP)' do
        manager.apply_delta(delta)

        existing_position.reload
        # (30*240 + 20*260) / 50 = 248.0
        expect(existing_position.qty).to eq(50)
        expect(existing_position.avg_entry_price).to eq(248.0)
      end

      it 'updates wallet with new investment' do
        initial_cash = wallet.cash
        initial_invested = wallet.invested

        manager.apply_delta(delta)

        wallet.reload
        expect(wallet.cash).to eq(initial_cash - 5200.0)
        expect(wallet.invested).to eq(initial_invested + 5200.0)
      end
    end

    context 'when SELL reduces position' do
      let!(:position) do
        create(:position, agent: agent, ticker: 'AAPL',
               qty: 100, avg_entry_price: 145.0, current_value: 14500.0)
      end

      let(:trade) do
        create(:trade, :filled, agent: agent, ticker: 'AAPL', side: 'SELL',
               qty_filled: 40, avg_fill_price: 150.0, filled_value: 6000.0)
      end

      let(:delta) do
        { delta_qty: 40, delta_value: 6000.0 }
      end

      before do
        # Adjust wallet to reflect existing position's cost basis
        wallet.update!(cash: 5500.0, invested: 14500.0)
      end

      it 'reduces position quantity' do
        manager.apply_delta(delta)

        position.reload
        expect(position.qty).to eq(60)
      end

      it 'keeps original avg_entry_price' do
        manager.apply_delta(delta)

        position.reload
        expect(position.avg_entry_price).to eq(145.0)
      end

      it 'updates wallet with proceeds and cost basis' do
        initial_cash = wallet.cash
        initial_invested = wallet.invested

        manager.apply_delta(delta)

        wallet.reload
        # Cash increases by proceeds (40 * 150 = 6000)
        expect(wallet.cash).to eq(initial_cash + 6000.0)
        # Invested decreases by cost basis (40 * 145 = 5800)
        expect(wallet.invested).to eq(initial_invested - 5800.0)
      end
    end

    context 'when SELL closes position completely' do
      let!(:position) do
        create(:position, agent: agent, ticker: 'AAPL',
               qty: 50, avg_entry_price: 145.0, current_value: 7250.0)
      end

      let(:trade) do
        create(:trade, :filled, agent: agent, ticker: 'AAPL', side: 'SELL',
               qty_filled: 50, avg_fill_price: 155.0, filled_value: 7750.0)
      end

      let(:delta) do
        { delta_qty: 50, delta_value: 7750.0 }
      end

      before do
        # Adjust wallet to reflect existing position's cost basis (50 * 145 = 7250)
        wallet.update!(cash: 12750.0, invested: 7250.0)
      end

      it 'deletes position' do
        expect {
          manager.apply_delta(delta)
        }.to change { Position.count }.by(-1)

        expect(Position.find_by(agent: agent, ticker: 'AAPL')).to be_nil
      end

      it 'updates wallet with realized gain' do
        initial_cash = wallet.cash
        initial_invested = wallet.invested

        manager.apply_delta(delta)

        wallet.reload
        # Proceeds: 50 * 155 = 7750
        # Cost basis: 50 * 145 = 7250
        # Realized P&L: 500
        expect(wallet.cash).to eq(initial_cash + 7750.0)
        expect(wallet.invested).to eq(initial_invested - 7250.0)
      end
    end

    context 'when SELL creates dust position' do
      let!(:position) do
        create(:position, agent: agent, ticker: 'AAPL',
               qty: 100, avg_entry_price: 145.0)
      end

      let(:trade) do
        create(:trade, :filled, agent: agent, ticker: 'AAPL', side: 'SELL',
               qty_filled: 99.999, avg_fill_price: 150.0, filled_value: 14999.85)
      end

      let(:delta) do
        { delta_qty: 99.999, delta_value: 14999.85 }
      end

      before do
        # Adjust wallet to reflect existing position's cost basis (100 * 145 = 14500)
        wallet.update!(cash: 5500.0, invested: 14500.0)
      end

      it 'deletes position when qty < DUST_THRESHOLD (0.01)' do
        expect {
          manager.apply_delta(delta)
        }.to change { Position.count }.by(-1)
      end
    end

    context 'when transaction fails' do
      let(:trade) do
        create(:trade, :filled, agent: agent, ticker: 'TSLA', side: 'BUY',
               qty_filled: 50, avg_fill_price: 250.0, filled_value: 12500.0)
      end

      let(:delta) do
        { delta_qty: 50, delta_price: 250.0, delta_value: 12500.0 }
      end

      it 'rolls back position and wallet changes on error' do
        # Force wallet save to fail
        allow(wallet).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(wallet))

        expect {
          manager.apply_delta(delta)
        }.to raise_error(ActiveRecord::RecordInvalid)

        # Position should not be created
        expect(Position.find_by(agent: agent, ticker: 'TSLA')).to be_nil

        # Wallet should not be changed
        wallet.reload
        expect(wallet.cash).to eq(20000.0) # Original value
      end
    end

    context 'when SELL with realized loss' do
      let!(:position) do
        create(:position, agent: agent, ticker: 'AAPL',
               qty: 100, avg_entry_price: 155.0, current_value: 15500.0)
      end

      let(:trade) do
        create(:trade, :filled, agent: agent, ticker: 'AAPL', side: 'SELL',
               qty_filled: 50, avg_fill_price: 145.0, filled_value: 7250.0)
      end

      let(:delta) do
        { delta_qty: 50, delta_value: 7250.0 }
      end

      before do
        # Adjust wallet to reflect existing position's cost basis (100 * 155 = 15500)
        wallet.update!(cash: 4500.0, invested: 15500.0)
      end

      it 'records realized loss correctly' do
        initial_cash = wallet.cash
        initial_invested = wallet.invested

        manager.apply_delta(delta)

        wallet.reload
        # Proceeds: 50 * 145 = 7250
        # Cost basis: 50 * 155 = 7750
        # Realized P&L: -500 (loss)
        expect(wallet.cash).to eq(initial_cash + 7250.0)
        expect(wallet.invested).to eq(initial_invested - 7750.0)
      end
    end
  end
end
