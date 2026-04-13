require 'rails_helper'

RSpec.describe Trades::FillProcessorService, type: :service do
  let(:agent) { create(:agent, :westin) }
  let(:trade) { create(:trade, :executing, agent: agent, ticker: 'AAPL', qty_requested: 100) }
  let(:processor) { described_class.new(trade) }

  describe '#process_fill' do
    context 'when first fill (complete)' do
      it 'records fill with correct delta' do
        result = processor.process_fill(
          qty_filled: 100,
          avg_fill_price: 150.0,
          final: true
        )

        expect(result[:delta_qty]).to eq(100)
        expect(result[:delta_value]).to eq(15000.0)
        expect(result[:filled_value]).to eq(15000.0)
        expect(result[:status]).to eq('FILLED')

        trade.reload
        expect(trade.qty_filled).to eq(100)
        expect(trade.avg_fill_price).to eq(150.0)
        expect(trade.filled_value).to eq(15000.0)
        expect(trade.status).to eq('FILLED')
      end

      it 'creates TradeEvent audit log' do
        expect {
          processor.process_fill(
            qty_filled: 100,
            avg_fill_price: 150.0,
            final: true
          )
        }.to change { TradeEvent.count }.by_at_least(1)

        # Find the FILLED event (there may be multiple events from AASM callbacks)
        filled_event = TradeEvent.where(trade: trade, event_type: 'FILLED').last
        expect(filled_event).to be_present
        expect(filled_event.trade).to eq(trade)
      end
    end

    context 'when partial fill' do
      it 'records partial fill with PARTIALLY_FILLED status' do
        result = processor.process_fill(
          qty_filled: 50,
          avg_fill_price: 150.0,
          final: false
        )

        expect(result[:delta_qty]).to eq(50)
        expect(result[:delta_value]).to eq(7500.0)
        expect(result[:status]).to eq('PARTIALLY_FILLED')

        trade.reload
        expect(trade.qty_filled).to eq(50)
        expect(trade.status).to eq('PARTIALLY_FILLED')
      end
    end

    context 'when multi-fill accumulation' do
      it 'calculates deltas correctly for second fill' do
        # First fill: 50 @ 150.0
        processor.process_fill(
          qty_filled: 50,
          avg_fill_price: 150.0,
          final: false
        )

        # Second fill: 100 total @ 151.0 average
        result = processor.process_fill(
          qty_filled: 100,
          avg_fill_price: 151.0,
          final: true
        )

        expect(result[:delta_qty]).to eq(50) # 100 - 50
        expect(result[:delta_value]).to eq(7600.0) # (100 * 151.0) - (50 * 150.0)
        expect(result[:status]).to eq('FILLED')

        trade.reload
        expect(trade.qty_filled).to eq(100)
        expect(trade.avg_fill_price).to be_within(0.01).of(151.0)
      end

      it 'handles three partial fills correctly' do
        # Fill 1: 30 @ 150.0
        processor.process_fill(qty_filled: 30, avg_fill_price: 150.0, final: false)

        # Fill 2: 60 @ 151.0 avg
        processor.process_fill(qty_filled: 60, avg_fill_price: 151.0, final: false)

        # Fill 3: 100 @ 152.0 avg (complete)
        result = processor.process_fill(qty_filled: 100, avg_fill_price: 152.0, final: true)

        expect(result[:delta_qty]).to eq(40) # 100 - 60
        expect(result[:status]).to eq('FILLED')

        trade.reload
        expect(trade.qty_filled).to eq(100)
        expect(trade.avg_fill_price).to be_within(0.01).of(152.0)
      end
    end

    context 'when fill price unavailable' do
      it 'uses quote price fallback' do
        # Mock broker service
        broker = instance_double(Alpaca::BrokerService)
        allow(Alpaca::BrokerService).to receive(:new).and_return(broker)
        allow(broker).to receive(:get_quote).with(
          ticker: 'AAPL',
          side: 'BUY'
        ).and_return({ success: true, price: 149.5 })

        result = processor.process_fill(
          qty_filled: 100,
          avg_fill_price: 0, # No fill price
          final: true
        )

        expect(result[:avg_fill_price]).to eq(149.5)
      end

      it 'returns 0 delta when quote fetch and fill price both fail' do
        broker = instance_double(Alpaca::BrokerService)
        allow(Alpaca::BrokerService).to receive(:new).and_return(broker)
        allow(broker).to receive(:get_quote).and_return({ success: false, error: 'API error' })

        result = processor.process_fill(
          qty_filled: 100,
          avg_fill_price: 0,
          final: true
        )

        expect(result[:delta_qty]).to eq(0)
      end
    end

    context 'when cleaning dust quantities' do
      it 'treats very small qty as 0' do
        result = processor.process_fill(
          qty_filled: 0.0000001, # Less than DUST_THRESHOLD
          avg_fill_price: 150.0,
          final: true
        )

        expect(result[:delta_qty]).to eq(0)
        trade.reload
        expect(trade.qty_filled).to eq(0)
      end
    end

    context 'when recording alpaca_order_id' do
      it 'saves order ID to trade' do
        processor.process_fill(
          qty_filled: 100,
          avg_fill_price: 150.0,
          alpaca_order_id: 'alpaca-12345',
          final: true
        )

        trade.reload
        expect(trade.alpaca_order_id).to eq('alpaca-12345')
      end
    end

    context 'when processing immediate sell fills in legacy mode' do
      let(:trade) { create(:trade, :executing, :sell, agent: agent, ticker: 'AAPL', qty_requested: 10) }

      before do
        allow(LedgerMigration).to receive(:write_guard_enabled?).and_return(false)
        allow(LedgerMigration).to receive(:write_to_ledger?).and_return(false)

        create(:position, agent: agent, ticker: 'AAPL', qty: 10.0, avg_entry_price: 100.0, current_value: 1000.0)
        create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 10.0, cost_basis_per_share: 100.0, total_cost_basis: 1000.0)
        agent.wallet.update!(cash: 0.0, invested: 1000.0)
      end

      it 'creates fill artifacts so realized pnl is captured' do
        expect {
          processor.process_fill(
            qty_filled: 10.0,
            avg_fill_price: 90.0,
            alpaca_order_id: 'sell-order-123',
            final: true
          )
        }.to change(BrokerFill, :count).by(1)
         .and change { PositionLot.closed.where(agent: agent, ticker: 'AAPL').count }.by(1)

        closed_lot = PositionLot.closed.find_by(agent: agent, ticker: 'AAPL')
        expect(closed_lot.realized_pnl).to eq(-100.0)
        expect(BrokerFill.last.fill_id_confidence).to eq('order_derived')
      end
    end
  end
end
