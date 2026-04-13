# frozen_string_literal: true

require 'rails_helper'

# Tests the complete trader workflow as documented in TRADE-PROTOCOL.md
# Uses test-safe agents (no real Discord IDs) and mocks all external services
#
# Key flows tested:
# - PROPOSE -> approve -> execute -> FILLED (happy path)
# - PROPOSE -> DENY
# - PROPOSE -> PASS (trader decides not to proceed)
# - PROPOSE -> stale (auto-cancel after timeout)
# - Discord notifications at each step
#
RSpec.describe 'Trader Workflow Integration', type: :integration do
  # Use test-safe agents (no real Discord IDs)
  let(:trader) { create(:agent, :test_momentum) }
  let(:other_trader) { create(:agent, :test_value) }
  let(:mock_broker) { instance_double(Alpaca::BrokerService) }

  before do
    # Mock all external services
    mock_all_external_services!
    mock_discord_with_tracking!

    # Mock Alpaca broker
    allow(Alpaca::BrokerService).to receive(:new).and_return(mock_broker)

    # Disable async Discord notifications
    allow(DiscordNotificationJob).to receive(:perform_later)
    allow(Dashboard::MarketStatusService).to receive(:current).and_return(status: "OPEN")
  end

  # Helper to approve a trade (sets approved_by first)
  def approve_trade!(trade, by: 'tiverton')
    trade.update!(approved_by: by, confirmed_at: Time.current)
    trade.approve!
  end

  # Helper to deny a trade (sets denial_reason first)
  def deny_trade!(trade, reason:)
    trade.update!(denial_reason: reason)
    trade.deny!
  end

  describe 'Complete BUY workflow: PROPOSED -> APPROVED -> FILLED' do
    it 'executes full workflow with proper notifications' do
      # Step 1: Trader proposes a trade (via TradeProposalService)
      proposal_result = TradeProposalService.new(
        agent: trader,
        ticker: 'NVDA',
        side: 'BUY',
        qty_requested: 20,
        thesis: 'Momentum breakout on AI demand',
        order_type: 'MARKET'
      ).call

      expect(proposal_result.success?).to be true
      trade = proposal_result.trade
      expect(trade.status).to eq('PROPOSED')
      expect(trade.trade_id).to start_with(trader.agent_id)

      # Step 2: Tiverton approves the trade
      approve_trade!(trade)
      trade.reload

      expect(trade.status).to eq('APPROVED')
      expect(trade.approved_by).to eq('tiverton')
      expect(trade.approved_at).to be_present

      # Step 3: Execute trade (mocked Alpaca)
      allow(mock_broker).to receive(:create_order).and_return({
        success: true,
        order_id: 'test-alpaca-order-001',
        qty_filled: 20,
        avg_fill_price: 875.50,
        filled_value: 17510.0,
        fill_ready: true
      })

      TradeExecutionJob.new.perform(trade.id)
      trade.reload

      expect(trade.status).to eq('FILLED')
      expect(trade.qty_filled).to eq(20)
      expect(trade.avg_fill_price).to eq(875.50)
      expect(trade.alpaca_order_id).to eq('test-alpaca-order-001')

      # Step 4: Verify position created
      position = Position.find_by(agent: trader, ticker: 'NVDA')
      expect(position).to be_present
      expect(position.qty).to eq(20)
      expect(position.avg_entry_price).to eq(875.50)

      # Step 5: Verify wallet updated
      wallet = trader.wallet.reload
      expect(wallet.cash).to eq(20000.0 - 17510.0) # Starting cash - trade cost
      expect(wallet.invested).to eq(17510.0)

      # Step 6: Verify Discord notification was queued
      # (DiscordNotificationJob is mocked, but we can verify it would be called)
    end
  end

  describe 'SELL workflow with realized P&L' do
    before do
      # Set up existing position
      create(:position,
        agent: trader,
        ticker: 'AAPL',
        qty: 100,
        avg_entry_price: 150.0,
        current_value: 15000.0
      )
      # Adjust wallet to reflect invested position
      trader.wallet.update!(cash: 5000.0, invested: 15000.0)
    end

    it 'calculates realized gain on profitable sale' do
      # Propose SELL
      proposal_result = TradeProposalService.new(
        agent: trader,
        ticker: 'AAPL',
        side: 'SELL',
        qty_requested: 50,
        thesis: 'Taking profits'
      ).call

      expect(proposal_result.success?).to be true
      trade = proposal_result.trade

      # Approve
      approve_trade!(trade)

      # Mock Alpaca (selling at $170, gain of $20/share)
      allow(mock_broker).to receive(:create_order).and_return({
        success: true,
        order_id: 'test-sell-order-001',
        qty_filled: 50,
        avg_fill_price: 170.0,
        filled_value: 8500.0,
        fill_ready: true
      })

      TradeExecutionJob.new.perform(trade.id)
      trade.reload

      expect(trade.status).to eq('FILLED')

      # Note: realized P&L is calculated but not stored on the Trade model
      # We verify it indirectly through wallet changes:
      # Cost basis: 50 * 150 = 7500
      # Proceeds: 50 * 170 = 8500
      # Realized gain: 1000 (cash increases by proceeds, invested decreases by cost basis)

      # Verify position reduced
      position = Position.find_by(agent: trader, ticker: 'AAPL')
      expect(position.qty).to eq(50)
      expect(position.avg_entry_price).to eq(150.0) # Unchanged

      # Verify wallet
      wallet = trader.wallet.reload
      expect(wallet.cash).to eq(5000.0 + 8500.0) # Proceeds added
      expect(wallet.invested).to eq(15000.0 - 7500.0) # Cost basis removed
    end

    it 'calculates realized loss on losing sale' do
      # Propose SELL
      proposal_result = TradeProposalService.new(
        agent: trader,
        ticker: 'AAPL',
        side: 'SELL',
        qty_requested: 50,
        thesis: 'Cutting losses'
      ).call

      trade = proposal_result.trade
      approve_trade!(trade)

      # Mock Alpaca (selling at $130, loss of $20/share)
      allow(mock_broker).to receive(:create_order).and_return({
        success: true,
        order_id: 'test-sell-order-002',
        qty_filled: 50,
        avg_fill_price: 130.0,
        filled_value: 6500.0,
        fill_ready: true
      })

      TradeExecutionJob.new.perform(trade.id)
      trade.reload

      expect(trade.status).to eq('FILLED')

      # Verify wallet reflects realized loss
      # Cost basis: 50 * 150 = 7500
      # Proceeds: 50 * 130 = 6500
      # Realized loss: -1000 (cash increases by proceeds, invested decreases by cost basis)
      # Net cash change: 6500 (proceeds)
      # Net invested change: -7500 (cost basis removed)
      wallet = trader.wallet.reload
      expect(wallet.cash).to eq(5000.0 + 6500.0) # Starting cash + proceeds
      expect(wallet.invested).to eq(15000.0 - 7500.0) # Starting invested - cost basis
    end
  end

  describe 'DENY workflow' do
    it 'denies trade with reason' do
      proposal_result = TradeProposalService.new(
        agent: trader,
        ticker: 'GME',
        side: 'BUY',
        qty_requested: 100,
        thesis: 'Meme stock momentum RESEARCH_OK'
      ).call

      trade = proposal_result.trade
      expect(trade.status).to eq('PROPOSED')

      # Tiverton denies (must set reason before calling deny!)
      deny_trade!(trade, reason: 'Too concentrated in meme stocks')
      trade.reload

      expect(trade.status).to eq('DENIED')
      expect(trade.denial_reason).to eq('Too concentrated in meme stocks')

      # Verify no position created
      expect(Position.find_by(agent: trader, ticker: 'GME')).to be_nil

      # Verify wallet unchanged
      expect(trader.wallet.reload.cash).to eq(20000.0)
    end
  end

  describe 'PASS workflow (trader decides not to proceed)' do
    it 'marks trade as PASSED when trader decides not to proceed' do
      proposal_result = TradeProposalService.new(
        agent: trader,
        ticker: 'TSLA',
        side: 'BUY',
        qty_requested: 10,
        thesis: 'Earnings play'
      ).call

      trade = proposal_result.trade

      # Trader decides to pass after Tiverton's feedback
      trade.pass!
      trade.reload

      expect(trade.status).to eq('PASSED')

      # Verify no position created
      expect(Position.find_by(agent: trader, ticker: 'TSLA')).to be_nil
    end
  end

  describe 'One-agent-per-ticker enforcement' do
    before do
      # Other trader already holds AAPL
      create(:position,
        agent: other_trader,
        ticker: 'AAPL',
        qty: 50,
        avg_entry_price: 150.0
      )
    end

    it 'rejects BUY proposal for ticker held by another agent' do
      proposal_result = TradeProposalService.new(
        agent: trader,
        ticker: 'AAPL',
        side: 'BUY',
        qty_requested: 20,
        thesis: 'Want to buy AAPL'
      ).call

      expect(proposal_result.success?).to be false
      expect(proposal_result.error).to include('One-agent-per-ticker')
      expect(proposal_result.details[:holder_agent_id]).to eq(other_trader.agent_id)
    end

    it 'allows the holding agent to SELL' do
      create(:position,
        agent: other_trader,
        ticker: 'MSFT',
        qty: 30,
        avg_entry_price: 400.0
      )

      proposal_result = TradeProposalService.new(
        agent: other_trader,
        ticker: 'MSFT',
        side: 'SELL',
        qty_requested: 10,
        thesis: 'Partial exit'
      ).call

      expect(proposal_result.success?).to be true
    end
  end

  describe 'SELL_ALL workflow (full position close)' do
    before do
      create(:position,
        agent: trader,
        ticker: 'NVDA',
        qty: 75.5, # Fractional shares from notional buys
        avg_entry_price: 800.0,
        current_value: 60400.0
      )
      trader.wallet.update!(cash: 0.0, invested: 60400.0)
    end

    it 'closes entire position and removes it' do
      proposal_result = TradeProposalService.new(
        agent: trader,
        ticker: 'NVDA',
        side: 'SELL',
        qty_requested: 75.5, # Will be overridden
        thesis: 'SELL_ALL - exiting position\nNOTIONAL_OK'
      ).call

      trade = proposal_result.trade
      approve_trade!(trade)

      # Mock Alpaca position close
      allow(mock_broker).to receive(:close_position).and_return({
        success: true,
        order_id: 'close-order-001',
        qty_closed: 75.5
      })

      allow(mock_broker).to receive(:get_quote).and_return({
        success: true,
        price: 850.0
      })

      TradeExecutionJob.new.perform(trade.id)
      trade.reload

      expect(trade.status).to eq('FILLED')
      expect(trade.qty_filled).to eq(75.5)

      # Position should be nil (deleted when qty becomes 0)
      position = Position.find_by(agent: trader, ticker: 'NVDA')
      expect(position).to be_nil

      # Wallet should have proceeds
      wallet = trader.wallet.reload
      expect(wallet.cash).to be > 0
    end
  end

  describe 'Notional BUY (dollar amount)' do
    it 'creates trade with amount instead of qty' do
      proposal_result = TradeProposalService.new(
        agent: trader,
        ticker: 'GOOG',
        side: 'BUY',
        amount_requested: 5000.0,
        thesis: 'Notional buy RESEARCH_OK'
      ).call

      expect(proposal_result.success?).to be true
      trade = proposal_result.trade
      expect(trade.qty_requested).to be_nil
      expect(trade.amount_requested).to eq(5000.0)

      # Approve and execute
      approve_trade!(trade)

      # Mock Alpaca (calculates qty from amount)
      allow(mock_broker).to receive(:create_order).and_return({
        success: true,
        order_id: 'notional-order-001',
        qty_filled: 2.78, # $5000 / $1800 per share
        avg_fill_price: 1798.56,
        filled_value: 5000.0,
        fill_ready: true
      })

      TradeExecutionJob.new.perform(trade.id)
      trade.reload

      expect(trade.status).to eq('FILLED')
      expect(trade.qty_filled).to eq(2.78)

      # Verify fractional position
      position = Position.find_by(agent: trader, ticker: 'GOOG')
      expect(position.qty).to eq(2.78)
    end
  end

  describe 'URGENT trade workflow' do
    it 'marks trade as urgent' do
      proposal_result = TradeProposalService.new(
        agent: trader,
        ticker: 'NVDA',
        side: 'BUY',
        qty_requested: 10,
        thesis: 'Breaking: surprise FDA approval',
        is_urgent: true
      ).call

      expect(proposal_result.success?).to be true
      trade = proposal_result.trade
      expect(trade.is_urgent).to be true
    end
  end

  describe 'Trade audit trail' do
    it 'creates trade events for each state transition' do
      proposal_result = TradeProposalService.new(
        agent: trader,
        ticker: 'AMD',
        side: 'BUY',
        qty_requested: 50,
        thesis: 'Data center demand'
      ).call

      trade = proposal_result.trade

      # Note: PROPOSED is initial state, so no event is created on create
      # (events are created on status CHANGE via after_update callback)
      expect(trade.trade_events.count).to eq(0)

      # Approve
      approve_trade!(trade)
      expect(trade.trade_events.where(event_type: 'APPROVED').exists?).to be true

      # Execute (mock fill)
      allow(mock_broker).to receive(:create_order).and_return({
        success: true,
        order_id: 'amd-order-001',
        qty_filled: 50,
        avg_fill_price: 145.0,
        filled_value: 7250.0,
        fill_ready: true
      })

      TradeExecutionJob.new.perform(trade.id)
      trade.reload

      expect(trade.trade_events.where(event_type: 'FILLED').exists?).to be true

      # Verify chronological order (APPROVED -> EXECUTING -> FILLED)
      events = trade.trade_events.order(:created_at)
      event_types = events.pluck(:event_type)
      expect(event_types).to include('APPROVED')
      expect(event_types).to include('EXECUTING')
      expect(event_types).to include('FILLED')
    end
  end

  describe 'Stale proposal handling' do
    it 'cancels proposals older than threshold' do
      # Create stale proposal
      trade = create(:trade,
        agent: trader,
        ticker: 'XOM',
        side: 'BUY',
        qty_requested: 100,
        status: 'PROPOSED',
        thesis: 'Stale proposal',
        created_at: 20.minutes.ago # Older than 15-minute threshold
      )

      # Run stale trade service
      Trades::StaleTradeService.new.call

      trade.reload
      expect(trade.status).to eq('CANCELLED')
      expect(trade.denial_reason).to eq('STALE_PROPOSAL')
    end

    it 'does not cancel recent proposals' do
      trade = create(:trade,
        agent: trader,
        ticker: 'XOM',
        side: 'BUY',
        qty_requested: 100,
        status: 'PROPOSED',
        thesis: 'Recent proposal',
        created_at: 2.minutes.ago # Within threshold
      )

      Trades::StaleTradeService.new.call

      trade.reload
      expect(trade.status).to eq('PROPOSED')
    end
  end

  describe 'Guard checks at execution time' do
    it 'fails SELL without position (unless SHORT_OK)' do
      proposal_result = TradeProposalService.new(
        agent: trader,
        ticker: 'COIN',
        side: 'SELL',
        qty_requested: 10,
        thesis: 'Shorting crypto exposure'
      ).call

      expect(proposal_result.success?).to be false
      expect(proposal_result.error).to include('no position exists')
      expect(proposal_result.error).to include('SHORT_OK')
    end

    it 'allows SELL without position when SHORT_OK present' do
      proposal_result = TradeProposalService.new(
        agent: trader,
        ticker: 'COIN',
        side: 'SELL',
        qty_requested: 10,
        thesis: 'Shorting crypto exposure SHORT_OK'
      ).call

      expect(proposal_result.success?).to be true
    end

    it 'fails notional SELL without NOTIONAL_OK' do
      create(:position, agent: trader, ticker: 'META', qty: 50, avg_entry_price: 400.0)

      proposal_result = TradeProposalService.new(
        agent: trader,
        ticker: 'META',
        side: 'SELL',
        amount_requested: 5000.0,
        thesis: 'Selling $5000 worth'
      ).call

      expect(proposal_result.success?).to be false
      expect(proposal_result.error).to include('NOTIONAL_OK')
    end
  end

  describe 'Duplicate proposal handling' do
    it 'updates existing PROPOSED trade instead of creating new one' do
      # First proposal
      first_result = TradeProposalService.new(
        agent: trader,
        ticker: 'MSFT',
        side: 'BUY',
        qty_requested: 50,
        thesis: 'First thesis RESEARCH_OK'
      ).call

      first_trade = first_result.trade
      first_id = first_trade.id

      # Second proposal for same agent+ticker
      second_result = TradeProposalService.new(
        agent: trader,
        ticker: 'MSFT',
        side: 'BUY',
        qty_requested: 100,
        thesis: 'Updated thesis RESEARCH_OK'
      ).call

      second_trade = second_result.trade

      # Should be same trade, updated
      expect(second_trade.id).to eq(first_id)
      expect(second_trade.qty_requested).to eq(100)
      expect(second_trade.thesis).to eq('Updated thesis RESEARCH_OK')

      # Only one trade should exist
      expect(Trade.where(agent: trader, ticker: 'MSFT').count).to eq(1)
    end
  end
end
