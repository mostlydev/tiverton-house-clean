# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TradeExecutionService, type: :service do
  include ExternalServicesMock

  let!(:agent) { create(:agent, agent_id: 'test_agent') }
  let(:broker_service) { instance_double(Alpaca::BrokerService) }

  before do
    mock_all_external_services!
    allow(Alpaca::BrokerService).to receive(:new).and_return(broker_service)
    allow(broker_service).to receive(:get_position_qty).and_return(nil)
    allow(broker_service).to receive(:create_order).and_return({
      success: true,
      order_id: 'test-order-123',
      qty_filled: 10.0,
      avg_fill_price: 150.0,
      fill_ready: true
    })
    allow(broker_service).to receive(:close_position).and_return({
      success: true,
      order_id: 'close-order-123',
      qty_closed: 10.0
    })
  end

  describe '#should_use_position_close?' do
    context 'in ledger mode' do
      before do
        allow(LedgerMigration).to receive(:read_from_ledger?).and_return(true)
      end

      it 'never uses position close API in ledger mode' do
        trade = create(:trade, :approved, agent: agent, ticker: 'AAPL', side: 'SELL', qty_requested: 10.0, thesis: 'SELL_ALL')
        service = TradeExecutionService.new(trade)

        expect(service.send(:should_use_position_close?)).to be false
      end

      it 'uses standard order even for 100% position sells' do
        create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 10.0)
        trade = create(:trade, :approved, agent: agent, ticker: 'AAPL', side: 'SELL', qty_requested: 10.0)
        service = TradeExecutionService.new(trade)

        expect(service.send(:should_use_position_close?)).to be false
      end
    end

    context 'in legacy mode' do
      before do
        allow(LedgerMigration).to receive(:read_from_ledger?).and_return(false)
      end

      it 'uses position close for SELL_ALL trades' do
        create(:position, agent: agent, ticker: 'AAPL', qty: 10)
        trade = create(:trade, :approved, agent: agent, ticker: 'AAPL', side: 'SELL', qty_requested: 10.0, thesis: 'SELL_ALL')
        service = TradeExecutionService.new(trade)

        expect(service.send(:should_use_position_close?)).to be true
      end

      it 'skips position close when other agents hold the ticker' do
        other_agent = create(:agent)
        create(:position, agent: agent, ticker: 'AAPL', qty: 10)
        create(:position, agent: other_agent, ticker: 'AAPL', qty: 5)
        trade = create(:trade, :approved, agent: agent, ticker: 'AAPL', side: 'SELL', qty_requested: 10.0, thesis: 'SELL_ALL')
        service = TradeExecutionService.new(trade)

        expect(service.send(:should_use_position_close?)).to be false
      end
    end
  end

  describe '#execute_order' do
    context 'in ledger mode' do
      before do
        allow(LedgerMigration).to receive(:read_from_ledger?).and_return(true)
        allow(LedgerMigration).to receive(:write_to_ledger?).and_return(true)
        allow(LedgerMigration).to receive(:block_legacy_write?).and_return(true)
      end

      it 'executes standard order for SELL trades' do
        create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 10.0)
        trade = create(:trade, :approved, :confirmed, agent: agent, ticker: 'AAPL', side: 'SELL', qty_requested: 10.0)
        service = TradeExecutionService.new(trade)

        expect(broker_service).to receive(:create_order).and_return({
          success: true,
          order_id: 'test-order-123',
          qty_filled: 10.0,
          avg_fill_price: 150.0,
          fill_ready: true
        })

        result = service.call
        expect(result.success?).to be true
      end

      it 'does not call position close API' do
        create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 10.0)
        trade = create(:trade, :approved, :confirmed, agent: agent, ticker: 'AAPL', side: 'SELL', qty_requested: 10.0, thesis: 'SELL_ALL')
        service = TradeExecutionService.new(trade)

        expect(broker_service).not_to receive(:close_position)
        expect(broker_service).to receive(:create_order).and_return({
          success: true,
          order_id: 'test-order-123',
          qty_filled: 10.0,
          avg_fill_price: 150.0,
          fill_ready: true
        })

        service.call
      end

      it 'uses broker position qty for SELL_ALL to avoid precision rejection' do
        create(:position_lot, :bootstrap, agent: agent, ticker: 'PRU', qty: 13.91226339)
        trade = create(
          :trade,
          :approved,
          agent: agent,
          ticker: 'PRU',
          side: 'SELL',
          qty_requested: 13.91226339,
          thesis: 'SELL_ALL - close position'
        )

        allow(broker_service).to receive(:get_position_qty).with(ticker: 'PRU').and_return(13.912263389)

        submitted = nil
        allow(broker_service).to receive(:create_order) do |**kwargs|
          submitted = kwargs
          {
            success: true,
            order_id: 'sell-pru-123',
            qty_filled: 13.912263389,
            avg_fill_price: 100.0,
            fill_ready: true
          }
        end

        result = TradeExecutionService.new(trade).call

        expect(result.success?).to be true
        expect(submitted[:qty]).to eq(13.912263389)
      end

      it 'does not snap SELL_ALL to full broker qty when another agent-sized remainder exists' do
        create(:position_lot, :bootstrap, agent: agent, ticker: 'PRU', qty: 1.0)
        trade = create(
          :trade,
          :approved,
          agent: agent,
          ticker: 'PRU',
          side: 'SELL',
          qty_requested: 1.0,
          thesis: 'SELL_ALL - close my slice'
        )

        # Simulate multi-agent/shared position at broker level.
        allow(broker_service).to receive(:get_position_qty).with(ticker: 'PRU').and_return(2.0)

        submitted = nil
        allow(broker_service).to receive(:create_order) do |**kwargs|
          submitted = kwargs
          {
            success: true,
            order_id: 'sell-pru-456',
            qty_filled: 1.0,
            avg_fill_price: 100.0,
            fill_ready: true
          }
        end

        result = TradeExecutionService.new(trade).call

        expect(result.success?).to be true
        expect(submitted[:qty]).to eq(1.0)
      end
    end
  end

  describe 'position lot closing on SELL fills' do
    before do
      allow(LedgerMigration).to receive(:read_from_ledger?).and_return(true)
      allow(LedgerMigration).to receive(:write_to_ledger?).and_return(true)
      allow(LedgerMigration).to receive(:block_legacy_write?).and_return(true)
    end

    it 'closes position lots via FIFO on SELL fill' do
      # Create position lots
      lot1 = create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 5.0, cost_basis_per_share: 100.0)
      lot2 = create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 5.0, cost_basis_per_share: 110.0)

      trade = create(:trade, :approved, :confirmed, agent: agent, ticker: 'AAPL', side: 'SELL', qty_requested: 8.0)

      allow(broker_service).to receive(:create_order).and_return({
        success: true,
        order_id: 'sell-order-123',
        qty_filled: 8.0,
        avg_fill_price: 120.0,
        fill_ready: true
      })

      service = TradeExecutionService.new(trade)
      result = service.call

      expect(result.success?).to be true

      # Lot 1 should be fully closed (FIFO)
      lot1.reload
      expect(lot1.closed_at).not_to be_nil
      expect(lot1.realized_pnl).to be_within(0.01).of(100.0) # 5 shares * $20 profit

      # Lot 2 is partially sold: FIFO splits the lot.
      # The original lot2 keeps the remaining open qty (2 shares),
      # and a new closed lot is created for the sold portion (3 shares).
      lot2.reload
      expect(lot2.qty).to be_within(0.01).of(2.0)
      expect(lot2.closed_at).to be_nil

      closed_portion = PositionLot.where(agent: agent, ticker: 'AAPL', cost_basis_per_share: 110.0)
                                  .where.not(closed_at: nil)
                                  .first
      expect(closed_portion).not_to be_nil
      expect(closed_portion.qty).to be_within(0.01).of(3.0)
      expect(closed_portion.realized_pnl).to be_within(0.01).of(30.0) # 3 shares * $10 profit
    end

    it 'creates broker fill record for lot tracking' do
      create(:position_lot, :bootstrap, agent: agent, ticker: 'AAPL', qty: 10.0)
      trade = create(:trade, :approved, :confirmed, agent: agent, ticker: 'AAPL', side: 'SELL', qty_requested: 10.0)

      allow(broker_service).to receive(:create_order).and_return({
        success: true,
        order_id: 'sell-order-123',
        qty_filled: 10.0,
        avg_fill_price: 120.0,
        fill_ready: true
      })

      expect {
        TradeExecutionService.new(trade).call
      }.to change(BrokerFill, :count).by(1)

      fill = BrokerFill.last
      expect(fill.trade).to eq(trade)
      expect(fill.qty).to eq(10.0)
      expect(fill.price).to eq(120.0)
    end
  end
end
