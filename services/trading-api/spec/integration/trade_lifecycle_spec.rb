# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Trade Lifecycle Integration', type: :integration do
  let(:agent) { create(:agent, :westin) }
  let(:wallet) { agent.wallet }
  let(:broker) { alpaca_mock_broker }

  # Helper to call FillIngestionService.ingest! with required broker_order_id
  # and raw_fill metadata so the service can auto-create BrokerOrder/Trade stubs
  def ingest_fill(service, agent:, broker_fill_id:, ticker:, side:, qty:, price:, executed_at:)
    service.ingest!(
      broker_fill_id: broker_fill_id,
      broker_order_id: "order-#{broker_fill_id}",
      ticker: ticker,
      side: side,
      qty: qty,
      price: price,
      executed_at: executed_at,
      agent: agent,
      raw_fill: { client_order_id: "#{agent.agent_id}-#{broker_fill_id}" }
    )
  end

  describe 'BUY workflow' do
    context 'simple market buy creating new position' do
      let(:trade) do
        create(:trade, :approved, agent: agent, ticker: 'NVDA', qty_requested: 10)
      end

      before do
        alpaca_mock_fill(broker, ticker: 'NVDA', side: 'buy', qty: 10, price: 500.0)
      end

      it 'creates position and updates wallet' do
        initial_cash = wallet.cash

        result = TradeExecutionService.new(trade, executed_by: 'test').call

        expect(result.success?).to be true

        # Trade filled
        trade.reload
        expect(trade.status).to eq('FILLED')
        expect(trade.qty_filled).to eq(10)
        expect(trade.avg_fill_price).to eq(500.0)
        expect(trade.filled_value).to eq(5000.0)

        # Position created
        position = Position.find_by(agent: agent, ticker: 'NVDA')
        expect(position.qty).to eq(10)
        expect(position.avg_entry_price).to eq(500.0)

        # Wallet updated
        wallet.reload
        expect(wallet.cash).to eq(initial_cash - 5000.0)
        expect(wallet.invested).to eq(5000.0)
      end
    end

    context 'buy adding to existing position (VWAP)' do
      let!(:existing_position) do
        create(:position, agent: agent, ticker: 'NVDA', qty: 10, avg_entry_price: 480.0, current_value: 4800.0)
      end

      let(:trade) do
        create(:trade, :approved, agent: agent, ticker: 'NVDA', qty_requested: 10)
      end

      before do
        wallet.update!(cash: 15200.0, invested: 4800.0)
        alpaca_mock_fill(broker, ticker: 'NVDA', side: 'buy', qty: 10, price: 520.0)
      end

      it 'adds to position with weighted average price' do
        result = TradeExecutionService.new(trade, executed_by: 'test').call

        expect(result.success?).to be true

        # Position updated with VWAP
        existing_position.reload
        expect(existing_position.qty).to eq(20)
        # VWAP: (10*480 + 10*520) / 20 = 500
        expect(existing_position.avg_entry_price).to eq(500.0)

        # Wallet updated
        wallet.reload
        expect(wallet.cash).to eq(10000.0) # 15200 - 5200
        expect(wallet.invested).to eq(10000.0) # 4800 + 5200
      end
    end

    context 'notional buy ($X worth)' do
      let(:trade) do
        create(:trade, :approved, :notional, :with_notional_ok, agent: agent, ticker: 'GOOGL',
               qty_requested: nil, amount_requested: 3000.0)
      end

      before do
        # $3000 at $150/share = 20 shares
        alpaca_mock_fill(broker, ticker: 'GOOGL', side: 'buy', qty: 20, price: 150.0)
      end

      it 'buys fractional shares based on notional amount' do
        result = TradeExecutionService.new(trade, executed_by: 'test').call

        expect(result.success?).to be true

        position = Position.find_by(agent: agent, ticker: 'GOOGL')
        expect(position.qty).to eq(20)
        expect(position.avg_entry_price).to eq(150.0)
      end
    end
  end

  describe 'SELL workflow' do
    context 'partial sell with realized gain' do
      let!(:position) do
        create(:position, agent: agent, ticker: 'AAPL', qty: 100, avg_entry_price: 150.0, current_value: 15000.0)
      end

      let(:trade) do
        create(:trade, :approved, :sell, agent: agent, ticker: 'AAPL', qty_requested: 40)
      end

      before do
        wallet.update!(cash: 5000.0, invested: 15000.0)
        # Selling at $160 (bought at $150) = $10/share profit
        alpaca_mock_fill(broker, ticker: 'AAPL', side: 'sell', qty: 40, price: 160.0)
      end

      it 'reduces position and records realized P&L' do
        initial_cash = wallet.cash
        initial_invested = wallet.invested

        result = TradeExecutionService.new(trade, executed_by: 'test').call

        expect(result.success?).to be true

        # Position reduced
        position.reload
        expect(position.qty).to eq(60)
        expect(position.avg_entry_price).to eq(150.0) # Unchanged

        # Wallet updated
        wallet.reload
        # Proceeds: 40 * 160 = 6400
        expect(wallet.cash).to eq(initial_cash + 6400.0)
        # Cost basis removed: 40 * 150 = 6000
        expect(wallet.invested).to eq(initial_invested - 6000.0)
        # Realized P&L: 6400 - 6000 = 400 gain
      end
    end

    context 'partial sell with realized loss' do
      let!(:position) do
        create(:position, agent: agent, ticker: 'META', qty: 50, avg_entry_price: 400.0, current_value: 20000.0)
      end

      let(:trade) do
        create(:trade, :approved, :sell, agent: agent, ticker: 'META', qty_requested: 20)
      end

      before do
        wallet.update!(cash: 0.0, invested: 20000.0)
        # Selling at $350 (bought at $400) = $50/share loss
        alpaca_mock_fill(broker, ticker: 'META', side: 'sell', qty: 20, price: 350.0)
      end

      it 'correctly records realized loss' do
        result = TradeExecutionService.new(trade, executed_by: 'test').call

        expect(result.success?).to be true

        # Position reduced
        position.reload
        expect(position.qty).to eq(30)

        # Wallet updated
        wallet.reload
        # Proceeds: 20 * 350 = 7000
        expect(wallet.cash).to eq(7000.0)
        # Cost basis removed: 20 * 400 = 8000
        expect(wallet.invested).to eq(12000.0)
        # Realized P&L: 7000 - 8000 = -1000 loss
      end
    end

    context 'full position close (SELL_ALL)' do
      let!(:position) do
        create(:position, agent: agent, ticker: 'TSLA', qty: 25, avg_entry_price: 200.0, current_value: 5000.0)
      end

      let(:trade) do
        create(:trade, :approved, :sell, :with_sell_all, agent: agent, ticker: 'TSLA',
               qty_requested: nil, amount_requested: 1.0) # Amount doesn't matter for SELL_ALL
      end

      before do
        wallet.update!(cash: 15000.0, invested: 5000.0)
        alpaca_mock_close(broker, ticker: 'TSLA', qty: 25, price: 220.0)
      end

      it 'closes entire position' do
        result = TradeExecutionService.new(trade, executed_by: 'test').call

        expect(result.success?).to be true

        # Position deleted
        expect(Position.find_by(agent: agent, ticker: 'TSLA')).to be_nil

        # Trade has expanded qty
        trade.reload
        expect(trade.qty_requested).to eq(25)

        # Wallet updated with proceeds
        wallet.reload
        # Proceeds: 25 * 220 = 5500
        expect(wallet.cash).to eq(20500.0)
        # Cost basis: 25 * 200 = 5000
        expect(wallet.invested).to eq(0.0)
      end
    end

    context 'sell that results in dust position' do
      let!(:position) do
        create(:position, agent: agent, ticker: 'AMD', qty: 100, avg_entry_price: 100.0, current_value: 10000.0)
      end

      let(:trade) do
        create(:trade, :approved, :sell, agent: agent, ticker: 'AMD', qty_requested: 99.995)
      end

      before do
        wallet.update!(cash: 10000.0, invested: 10000.0)
        alpaca_mock_close(broker, ticker: 'AMD', qty: 99.995, price: 110.0)
      end

      it 'cleans up dust position' do
        result = TradeExecutionService.new(trade, executed_by: 'test').call

        expect(result.success?).to be true

        # Dust position should be deleted (< 0.01 shares remaining)
        expect(Position.find_by(agent: agent, ticker: 'AMD')).to be_nil
      end
    end
  end

  describe 'order states' do
    context 'when order is pending (not filled yet)' do
      let(:trade) do
        create(:trade, :approved, agent: agent, ticker: 'COIN', qty_requested: 50)
      end

      before do
        alpaca_mock_pending(broker, ticker: 'COIN')
      end

      it 'keeps trade in EXECUTING state without creating position' do
        result = TradeExecutionService.new(trade, executed_by: 'test').call

        trade.reload
        expect(trade.status).to eq('EXECUTING')
        expect(trade.alpaca_order_id).to be_present
        expect(trade.qty_filled).to be_nil

        # No position yet
        expect(Position.find_by(agent: agent, ticker: 'COIN')).to be_nil

        # Wallet unchanged
        wallet.reload
        expect(wallet.cash).to eq(20000.0)
        expect(wallet.invested).to eq(0.0)
      end
    end

    context 'when order fails' do
      let(:trade) do
        create(:trade, :approved, agent: agent, ticker: 'GME', qty_requested: 1000)
      end

      before do
        alpaca_mock_failure(broker, error: 'insufficient buying power')
      end

      it 'marks trade as FAILED' do
        result = TradeExecutionService.new(trade, executed_by: 'test').call

        expect(result.success?).to be false

        trade.reload
        expect(trade.status).to eq('FAILED')
        expect(trade.execution_error).to eq('insufficient buying power')

        # No position created
        expect(Position.find_by(agent: agent, ticker: 'GME')).to be_nil
      end
    end
  end

  describe 'guard checks' do
    context 'selling without position' do
      let(:trade) do
        create(:trade, :approved, :sell, agent: agent, ticker: 'PLTR', qty_requested: 10)
      end

      it 'fails with guard error' do
        result = TradeExecutionService.new(trade, executed_by: 'test').call

        expect(result.success?).to be false
        expect(result.details[:guard_error]).to be true
      end
    end

    context 'selling more than position size' do
      let!(:position) do
        create(:position, agent: agent, ticker: 'PLTR', qty: 10, avg_entry_price: 20.0)
      end

      let(:trade) do
        create(:trade, :approved, :sell, agent: agent, ticker: 'PLTR', qty_requested: 50)
      end

      before do
        wallet.update!(cash: 19800.0, invested: 200.0)
      end

      it 'fails with guard error' do
        result = TradeExecutionService.new(trade, executed_by: 'test').call

        expect(result.success?).to be false
        expect(result.details[:guard_error]).to be true
      end
    end
  end

  describe 'realized P&L ledger posting (lot-based)' do
    let(:service) { Broker::FillIngestionService.new }

    before do
      # System agent needed for stub broker order creation during fill ingestion
      create(:agent, agent_id: 'system', name: 'System') unless Agent.exists?(agent_id: 'system')
    end

    context 'sell with gain posts P&L to ledger' do
      it 'creates position lot on buy and posts P&L on sell' do
        # 1. BUY: Create position lot
        buy_result = ingest_fill(service,
          agent: agent,
          broker_fill_id: 'test-buy-1',
          ticker: 'TSLA',
          side: 'buy',
          qty: 10.0,
          price: 400.0,
          executed_at: 1.day.ago
        )

        expect(buy_result.success).to be true

        # Verify lot created
        lot = PositionLot.open.find_by(ticker: 'TSLA', agent: agent)
        expect(lot).to be_present
        expect(lot.qty).to eq(10.0)
        expect(lot.cost_basis_per_share).to eq(400.0)

        # 2. SELL: Close lot and post P&L
        sell_result = ingest_fill(service,
          agent: agent,
          broker_fill_id: 'test-sell-1',
          ticker: 'TSLA',
          side: 'sell',
          qty: 10.0,
          price: 450.0,
          executed_at: Time.current
        )

        expect(sell_result.success).to be true

        # Verify lot closed with P&L
        lot.reload
        expect(lot.closed_at).to be_present
        expect(lot.realized_pnl).to eq(500.0) # (450 - 400) * 10

        # Verify P&L posted to ledger
        pnl_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:realized_pnl")
        expect(pnl_entries.count).to eq(1)
        expect(pnl_entries.sum(:amount).to_f).to eq(500.0)

        # Verify transaction balances
        pnl_txn = LedgerTransaction.where(source_type: 'PositionLot').last
        expect(pnl_txn.ledger_entries.sum(:amount).to_f).to be_within(0.01).of(0.0)
      end
    end

    context 'partial sell posts proportional P&L' do
      it 'closes part of lot and posts partial P&L' do
        # 1. BUY: Create position lot
        ingest_fill(service,
          agent: agent,
          broker_fill_id: 'test-buy-2',
          ticker: 'NVDA',
          side: 'buy',
          qty: 20.0,
          price: 500.0,
          executed_at: 1.day.ago
        )

        # 2. SELL: Close half the lot
        ingest_fill(service,
          agent: agent,
          broker_fill_id: 'test-sell-2',
          ticker: 'NVDA',
          side: 'sell',
          qty: 10.0,
          price: 550.0,
          executed_at: Time.current
        )

        # Verify one closed lot (the partial) and one open lot (remainder)
        closed_lots = PositionLot.closed.where(ticker: 'NVDA', agent: agent)
        expect(closed_lots.count).to eq(1)
        expect(closed_lots.first.qty).to eq(10.0)
        expect(closed_lots.first.realized_pnl).to eq(500.0) # (550 - 500) * 10

        open_lots = PositionLot.open.where(ticker: 'NVDA', agent: agent)
        expect(open_lots.count).to eq(1)
        expect(open_lots.first.qty).to eq(10.0)

        # Verify P&L posted
        pnl_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:realized_pnl")
        expect(pnl_entries.sum(:amount).to_f).to eq(500.0)
      end
    end

    context 'FIFO lot closing' do
      it 'closes oldest lots first' do
        # Create two lots at different prices
        ingest_fill(service,
          agent: agent,
          broker_fill_id: 'test-buy-3a',
          ticker: 'AAPL',
          side: 'buy',
          qty: 5.0,
          price: 150.0,
          executed_at: 2.days.ago
        )

        ingest_fill(service,
          agent: agent,
          broker_fill_id: 'test-buy-3b',
          ticker: 'AAPL',
          side: 'buy',
          qty: 5.0,
          price: 170.0,
          executed_at: 1.day.ago
        )

        # Sell entire position
        ingest_fill(service,
          agent: agent,
          broker_fill_id: 'test-sell-3',
          ticker: 'AAPL',
          side: 'sell',
          qty: 10.0,
          price: 180.0,
          executed_at: Time.current
        )

        # Verify both lots closed
        closed_lots = PositionLot.closed.where(ticker: 'AAPL', agent: agent).order(:opened_at)
        expect(closed_lots.count).to eq(2)

        # First lot (oldest, at $150)
        expect(closed_lots.first.cost_basis_per_share).to eq(150.0)
        expect(closed_lots.first.realized_pnl).to eq(150.0) # (180 - 150) * 5

        # Second lot (at $170)
        expect(closed_lots.second.cost_basis_per_share).to eq(170.0)
        expect(closed_lots.second.realized_pnl).to eq(50.0) # (180 - 170) * 5

        # Total P&L posted
        pnl_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:realized_pnl")
        expect(pnl_entries.sum(:amount).to_f).to eq(200.0) # 150 + 50
      end
    end
  end

  describe 'realized P&L calculation' do
    let!(:position) do
      create(:position, agent: agent, ticker: 'AMZN', qty: 20, avg_entry_price: 180.0, current_value: 3600.0)
    end

    before do
      wallet.update!(cash: 16400.0, invested: 3600.0)
    end

    context 'sell at profit' do
      let(:trade) do
        create(:trade, :approved, :sell, agent: agent, ticker: 'AMZN', qty_requested: 10)
      end

      before do
        alpaca_mock_fill(broker, ticker: 'AMZN', side: 'sell', qty: 10, price: 200.0)
      end

      it 'calculates correct realized gain' do
        TradeExecutionService.new(trade, executed_by: 'test').call

        wallet.reload
        # Proceeds: 10 * 200 = 2000
        # Cost basis: 10 * 180 = 1800
        # Realized P&L: +200

        # Cash: 16400 + 2000 = 18400
        expect(wallet.cash).to eq(18400.0)
        # Invested: 3600 - 1800 = 1800
        expect(wallet.invested).to eq(1800.0)
        # Total: 18400 + 1800 = 20200 (started at 20000, gained 200)
        expect(wallet.total_value).to eq(20200.0)
      end
    end

    context 'sell at loss' do
      let(:trade) do
        create(:trade, :approved, :sell, agent: agent, ticker: 'AMZN', qty_requested: 10)
      end

      before do
        alpaca_mock_fill(broker, ticker: 'AMZN', side: 'sell', qty: 10, price: 160.0)
      end

      it 'calculates correct realized loss' do
        TradeExecutionService.new(trade, executed_by: 'test').call

        wallet.reload
        # Proceeds: 10 * 160 = 1600
        # Cost basis: 10 * 180 = 1800
        # Realized P&L: -200

        # Cash: 16400 + 1600 = 18000
        expect(wallet.cash).to eq(18000.0)
        # Invested: 3600 - 1800 = 1800
        expect(wallet.invested).to eq(1800.0)
        # Total: 18000 + 1800 = 19800 (started at 20000, lost 200)
        expect(wallet.total_value).to eq(19800.0)
      end
    end
  end
end
