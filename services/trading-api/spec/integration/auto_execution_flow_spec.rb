# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Auto-Execution Flow', type: :integration do
  let(:agent) { create(:agent, :westin) }
  let(:mock_alpaca) { instance_double(Alpaca::BrokerService) }

  before do
    allow(Alpaca::BrokerService).to receive(:new).and_return(mock_alpaca)
    # Disable Discord notifications for tests
    allow(DiscordNotificationJob).to receive(:perform_later)
    allow(Dashboard::MarketStatusService).to receive(:current).and_return(status: "OPEN")
  end

  # Helper to approve a trade (sets approved_by first, as required by the model)
  def approve_trade!(trade, by: 'tiverton')
    trade.update!(approved_by: by, confirmed_at: Time.current)
    trade.approve!
  end

  describe 'Complete trade lifecycle: PROPOSED → FILLED' do
    context 'with market BUY order' do
      let(:trade) do
        create(:trade,
          agent: agent,
          ticker: 'AAPL',
          side: 'BUY',
          order_type: 'MARKET',
          qty_requested: 10,
          status: 'PROPOSED',
          thesis: 'Test BUY'
        )
      end

      it 'executes complete workflow when approved' do
        # Mock Alpaca order creation (market orders fill immediately)
        allow(mock_alpaca).to receive(:create_order).and_return({
          success: true,
          order_id: 'alpaca-order-123',
          qty_filled: 10,
          avg_fill_price: 150.0,
          filled_value: 1500.0,
          status: 'filled',
          fill_ready: true
        })

        # Step 1: Approve trade (triggers auto-execution)
        approve_trade!(trade)
        trade.reload

        expect(trade.status).to eq('APPROVED')
        expect(trade.approved_by).to eq('tiverton')

        # Step 2: Auto-execution via job
        TradeExecutionJob.new.perform(trade.id)
        trade.reload

        # Step 3: Verify trade is FILLED
        expect(trade.status).to eq('FILLED')
        expect(trade.alpaca_order_id).to eq('alpaca-order-123')
        expect(trade.qty_filled).to eq(10)
        expect(trade.avg_fill_price).to eq(150.0)
        expect(trade.filled_value).to eq(1500.0)

        # Step 4: Verify position created
        position = Position.find_by(agent: agent, ticker: 'AAPL')
        expect(position).to be_present
        expect(position.qty).to eq(10)
        expect(position.avg_entry_price).to eq(150.0)
        expect(position.current_value).to eq(1500.0)

        # Step 5: Verify wallet updated
        wallet = agent.wallet.reload
        expect(wallet.cash).to eq(20000.0 - 1500.0) # Default wallet 20k
        expect(wallet.invested).to eq(1500.0)

        # Step 6: Verify audit trail
        events = trade.trade_events.order(:created_at)
        expect(events.pluck(:event_type)).to include('FILLED')
      end
    end

    context 'with limit BUY order (not filled immediately)' do
      let(:trade) do
        create(:trade,
          agent: agent,
          ticker: 'AAPL',
          side: 'BUY',
          order_type: 'LIMIT',
          qty_requested: 10,
          limit_price: 145.0,
          status: 'PROPOSED',
          thesis: 'Test limit BUY'
        )
      end

      it 'submits order but waits for fill' do
        # Mock Alpaca order creation (limit order pending)
        allow(mock_alpaca).to receive(:create_order).and_return({
          success: true,
          order_id: 'alpaca-order-456',
          qty_filled: 0,
          avg_fill_price: 0,
          filled_value: 0,
          status: 'new',
          fill_ready: false
        })

        # Approve and execute
        approve_trade!(trade)
        TradeExecutionJob.new.perform(trade.id)
        trade.reload

        # Verify trade is EXECUTING (not FILLED)
        expect(trade.status).to eq('EXECUTING')
        expect(trade.alpaca_order_id).to eq('alpaca-order-456')
        expect(trade.qty_filled).to be_nil

        # Verify no position created yet
        position = Position.find_by(agent: agent, ticker: 'AAPL')
        expect(position).to be_nil

        # Verify wallet not updated yet
        wallet = agent.wallet.reload
        expect(wallet.cash).to eq(20000.0)
        expect(wallet.invested).to eq(0)
      end
    end

    context 'with SELL order' do
      let(:trade) do
        create(:trade,
          agent: agent,
          ticker: 'AAPL',
          side: 'SELL',
          order_type: 'MARKET',
          qty_requested: 5,
          status: 'PROPOSED',
          thesis: 'Test SELL'
        )
      end

      before do
        # Create existing position
        create(:position,
          agent: agent,
          ticker: 'AAPL',
          qty: 10,
          avg_entry_price: 140.0,
          current_value: 1400.0
        )
        # Adjust wallet to match position (cost basis: 10 * 140 = 1400)
        agent.wallet.update!(cash: 18600.0, invested: 1400.0)
      end

      it 'reduces position and updates wallet with proceeds' do
        # Mock Alpaca order creation
        allow(mock_alpaca).to receive(:create_order).and_return({
          success: true,
          order_id: 'alpaca-order-789',
          qty_filled: 5,
          avg_fill_price: 155.0,
          filled_value: 775.0,
          status: 'filled',
          fill_ready: true
        })

        # Execute workflow
        approve_trade!(trade)
        TradeExecutionJob.new.perform(trade.id)
        trade.reload

        # Verify trade is FILLED
        expect(trade.status).to eq('FILLED')
        expect(trade.qty_filled).to eq(5)
        expect(trade.avg_fill_price).to eq(155.0)

        # Verify position reduced
        position = Position.find_by(agent: agent, ticker: 'AAPL')
        expect(position.qty).to eq(5) # 10 - 5
        expect(position.avg_entry_price).to eq(140.0) # Unchanged

        # Verify wallet updated
        # Cash: 18600 + proceeds (775) = 19375
        # Invested: 1400 - cost_basis (700) = 700
        wallet = agent.wallet.reload
        expect(wallet.cash).to eq(18600.0 + 775.0)
        expect(wallet.invested).to eq(1400.0 - 700.0)
      end
    end

    context 'with SELL_ALL order' do
      let(:trade) do
        create(:trade,
          agent: agent,
          ticker: 'AAPL',
          side: 'SELL',
          order_type: 'MARKET',
          qty_requested: 50, # Will be overridden by SELL_ALL
          status: 'PROPOSED',
          thesis: 'SELL_ALL - closing position'
        )
      end

      before do
        # Create position to close
        create(:position,
          agent: agent,
          ticker: 'AAPL',
          qty: 100,
          avg_entry_price: 145.0,
          current_value: 14500.0
        )
        # Adjust wallet to match position (cost basis: 100 * 145 = 14500)
        agent.wallet.update!(cash: 5500.0, invested: 14500.0)
      end

      it 'expands qty to full position and closes' do
        # Mock Alpaca REST position close
        allow(mock_alpaca).to receive(:close_position).and_return({
          success: true,
          order_id: 'alpaca-close-123',
          qty_closed: 100,
          status: 'filled'
        })

        # Mock quote for fallback price (REST close doesn't return fill price)
        allow(mock_alpaca).to receive(:get_quote).and_return({
          success: true,
          price: 152.0
        })

        # Execute workflow
        approve_trade!(trade)
        TradeExecutionJob.new.perform(trade.id)
        trade.reload

        # Verify qty expanded
        expect(trade.qty_requested).to eq(100)

        # Verify trade is FILLED
        expect(trade.status).to eq('FILLED')
        expect(trade.qty_filled).to eq(100)

        # Verify position deleted
        position = Position.find_by(agent: agent, ticker: 'AAPL')
        expect(position).to be_nil

        # Verify wallet updated
        # Cash: 5500 + proceeds (100 * 152 = 15200) = 20700
        # Invested: 14500 - 14500 = 0 (position closed)
        wallet = agent.wallet.reload
        expect(wallet.cash).to eq(5500.0 + 15200.0)
        expect(wallet.invested).to eq(0)
      end
    end

    context 'with multi-agent position (SELL_ALL scoped to agent)' do
      let(:other_agent) { create(:agent, :logan) }
      let(:trade) do
        create(:trade,
          agent: agent,
          ticker: 'AAPL',
          side: 'SELL',
          order_type: 'MARKET',
          qty_requested: 50,
          status: 'PROPOSED',
          thesis: 'SELL_ALL - closing position'
        )
      end

      before do
        # Both agents hold same ticker
        create(:position, agent: agent, ticker: 'AAPL', qty: 50)
        create(:position, agent: other_agent, ticker: 'AAPL', qty: 30)

        # SELL_ALL now succeeds (scoped to agent's qty) using a standard order
        allow(mock_alpaca).to receive(:get_position_qty).with(ticker: 'AAPL').and_return(80.0)
        allow(mock_alpaca).to receive(:create_order).and_return({
          success: true,
          order_id: 'sell-all-multi-123',
          qty_filled: 50.0,
          avg_fill_price: 155.0,
          fill_ready: true
        })
      end

      it 'succeeds using agent-scoped qty and standard order' do
        approve_trade!(trade)
        TradeExecutionJob.new.perform(trade.id)
        trade.reload

        # SELL_ALL scoped to this agent's position qty (50), not entire broker position (80)
        expect(trade.qty_requested).to eq(50)
        expect(trade.status).to eq('FILLED')
      end
    end

    context 'when guard checks fail (SELL without position)' do
      let(:trade) do
        create(:trade,
          agent: agent,
          ticker: 'AAPL',
          side: 'SELL',
          order_type: 'MARKET',
          qty_requested: 10,
          status: 'PROPOSED',
          thesis: 'Testing sell with no position held'
        )
      end

      it 'fails before executing order' do
        allow(mock_alpaca).to receive(:create_order)
        approve_trade!(trade)
        TradeExecutionJob.new.perform(trade.id)
        trade.reload

        # Verify trade failed guard check - stays APPROVED because guard fails before EXECUTING
        expect(trade.status).to eq('APPROVED')
        expect(trade.execution_error).to include('no position exists')
        expect(mock_alpaca).not_to have_received(:create_order)
      end
    end

    context 'when Alpaca order creation fails' do
      let(:trade) do
        create(:trade,
          agent: agent,
          ticker: 'AAPL',
          side: 'BUY',
          order_type: 'MARKET',
          qty_requested: 10,
          status: 'PROPOSED',
          thesis: 'Test BUY failure'
        )
      end

      it 'marks trade as FAILED' do
        # Mock Alpaca failure
        allow(mock_alpaca).to receive(:create_order).and_return({
          success: false,
          error: 'Insufficient buying power'
        })

        approve_trade!(trade)
        TradeExecutionJob.new.perform(trade.id)
        trade.reload

        # Verify trade is FAILED
        expect(trade.status).to eq('FAILED')
        expect(trade.execution_error).to include('Insufficient buying power')

        # Verify no position created
        position = Position.find_by(agent: agent, ticker: 'AAPL')
        expect(position).to be_nil

        # Verify wallet unchanged
        wallet = agent.wallet.reload
        expect(wallet.cash).to eq(20000.0)
        expect(wallet.invested).to eq(0)
      end
    end
  end

  describe 'Partial fill reconciliation' do
    let!(:trade) do
      create(:trade,
        agent: agent,
        ticker: 'AAPL',
        side: 'BUY',
        order_type: 'LIMIT',
        qty_requested: 100,
        limit_price: 145.0,
        status: 'EXECUTING',
        alpaca_order_id: 'alpaca-order-partial',
        executed_by: 'sentinel',
        execution_started_at: 2.minutes.ago
      )
    end

    it 'processes multiple partial fills correctly' do
      # First partial fill: 30 shares @ 145.0
      allow(mock_alpaca).to receive(:get_order_status).and_return({
        success: true,
        status: 'partially_filled',
        qty_filled: 30,
        avg_fill_price: 145.0
      })

      Trades::OrderReconciliationService.new.call
      trade.reload

      expect(trade.status).to eq('PARTIALLY_FILLED')
      expect(trade.qty_filled).to eq(30)
      expect(trade.avg_fill_price).to eq(145.0)

      # Verify position created with partial qty
      position = Position.find_by(agent: agent, ticker: 'AAPL')
      expect(position.qty).to eq(30)

      # Second partial fill: 50 more shares @ 145.5 (different price)
      allow(mock_alpaca).to receive(:get_order_status).and_return({
        success: true,
        status: 'partially_filled',
        qty_filled: 80,
        avg_fill_price: 145.3
      })

      Trades::OrderReconciliationService.new.call
      trade.reload

      expect(trade.status).to eq('PARTIALLY_FILLED')
      expect(trade.qty_filled).to eq(80)
      # VWAP: (30*145 + 50*145.6) / 80 = 145.375 ≈ 145.3 (Alpaca calculates)
      expect(trade.avg_fill_price).to eq(145.3)

      # Verify position updated with VWAP
      position.reload
      expect(position.qty).to eq(80)

      # Final fill: 20 more shares @ 146.0
      allow(mock_alpaca).to receive(:get_order_status).and_return({
        success: true,
        status: 'filled',
        qty_filled: 100,
        avg_fill_price: 145.43
      })

      Trades::OrderReconciliationService.new.call
      trade.reload

      expect(trade.status).to eq('FILLED')
      expect(trade.qty_filled).to eq(100)
      expect(trade.avg_fill_price).to eq(145.43)

      # Verify final position
      position.reload
      expect(position.qty).to eq(100)
      expect(position.avg_entry_price).to eq(145.43)
    end
  end

  describe 'Order reconciliation timeout' do
    let!(:trade) do
      create(:trade,
        agent: agent,
        ticker: 'AAPL',
        side: 'BUY',
        order_type: 'LIMIT',
        qty_requested: 10,
        status: 'EXECUTING',
        executed_by: 'sentinel',
        execution_started_at: 6.minutes.ago, # > 5 minute timeout
        alpaca_order_id: nil # No order ID recorded
      )
    end

    before do
      trade.update_column(:updated_at, 6.minutes.ago)
    end

    it 'times out stale execution without order ID' do
      Trades::StaleTradeService.new.call
      trade.reload

      expect(trade.status).to eq('FAILED')
      expect(trade.execution_error).to include('Execution timeout')
    end
  end

  describe 'Multi-fill with position averaging (VWAP)' do
    let(:trade1) do
      create(:trade,
        agent: agent,
        ticker: 'AAPL',
        side: 'BUY',
        order_type: 'MARKET',
        qty_requested: 50,
        status: 'PROPOSED',
        thesis: 'First BUY'
      )
    end

    let(:trade2) do
      create(:trade,
        agent: agent,
        ticker: 'AAPL',
        side: 'BUY',
        order_type: 'MARKET',
        qty_requested: 30,
        status: 'PROPOSED',
        thesis: 'Second BUY (add to position)'
      )
    end

    it 'calculates VWAP correctly across multiple buys' do
      # First trade: 50 @ 140
      allow(mock_alpaca).to receive(:create_order).and_return({
        success: true,
        order_id: 'order-1',
        qty_filled: 50,
        avg_fill_price: 140.0,
        filled_value: 7000.0,
        fill_ready: true
      })

      approve_trade!(trade1)
      TradeExecutionJob.new.perform(trade1.id)

      position = Position.find_by(agent: agent, ticker: 'AAPL')
      expect(position.qty).to eq(50)
      expect(position.avg_entry_price).to eq(140.0)

      # Second trade: 30 @ 150
      allow(mock_alpaca).to receive(:create_order).and_return({
        success: true,
        order_id: 'order-2',
        qty_filled: 30,
        avg_fill_price: 150.0,
        filled_value: 4500.0,
        fill_ready: true
      })

      approve_trade!(trade2)
      TradeExecutionJob.new.perform(trade2.id)

      position.reload
      expect(position.qty).to eq(80)
      # VWAP: (50*140 + 30*150) / 80 = (7000 + 4500) / 80 = 143.75
      expect(position.avg_entry_price).to eq(143.75)
    end
  end
end
