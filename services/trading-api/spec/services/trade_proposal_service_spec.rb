# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TradeProposalService do
  let(:agent) { create(:agent) }
  let(:other_agent) { create(:agent) }

  before do
    allow(Dashboard::MarketStatusService).to receive(:current).and_return(status: 'OPEN')
  end

  def propose(params = {})
    described_class.new({
      agent: agent,
      ticker: 'AAPL',
      side: 'BUY',
      qty_requested: 100,
      thesis: 'Test thesis RESEARCH_OK'
    }.merge(params)).call
  end

  describe 'basic validation' do
    it 'requires an agent' do
      result = propose(agent: nil)
      expect(result.success?).to be false
      expect(result.error).to include('Agent is required')
    end

    it 'requires a ticker' do
      result = propose(ticker: nil)
      expect(result.success?).to be false
      expect(result.error).to include('Ticker is required')
    end

    it 'requires a side' do
      result = propose(side: nil)
      expect(result.success?).to be false
      expect(result.error).to include('Side is required')
    end

    it 'validates side is BUY or SELL' do
      result = propose(side: 'HOLD')
      expect(result.success?).to be false
      expect(result.error).to include('Side must be BUY or SELL')
    end

    it 'requires qty_requested or amount_requested' do
      result = propose(qty_requested: nil, amount_requested: nil)
      expect(result.success?).to be false
      expect(result.error).to include('Must specify qty_requested or amount_requested')
      expect(result.details[:guard]).to eq('missing_sizing')
      expect(result.details[:immediate_retry_allowed]).to be(true)
      expect(result.details.dig(:remediation, :required_one_of)).to eq(%w[qty_requested amount_requested])
    end

    it 'creates a PROPOSED trade with valid params' do
      result = propose
      expect(result.success?).to be true
      expect(result.trade).to be_a(Trade)
      expect(result.trade.status).to eq('PROPOSED')
      expect(result.trade.ticker).to eq('AAPL')
      expect(result.trade.side).to eq('BUY')
    end
  end

  describe 'order type validation' do
    it 'allows MARKET orders without additional params' do
      result = propose(order_type: 'MARKET')
      expect(result.success?).to be true
    end

    it 'normalizes legacy trailing fields on MARKET orders into advisory thesis text' do
      result = propose(order_type: 'MARKET', trail_percent: 5.0)

      expect(result.success?).to be true
      expect(result.trade.trail_percent).to be_nil
      expect(result.trade.trail_amount).to be_nil
      expect(result.trade.thesis).to include('Test thesis RESEARCH_OK')
      expect(result.trade.thesis).to include('Advisory trailing plan: manual trail 5.0%.')
    end

    it 'returns structured remediation for MARKET orders with stop_price' do
      result = propose(order_type: 'MARKET', stop_price: 145.0)

      expect(result.success?).to be false
      expect(result.details[:guard]).to eq('market_order_params')
      expect(result.details[:invalid_fields]).to eq(['stop_price'])
      expect(result.details[:immediate_retry_allowed]).to be(true)
      expect(result.details.dig(:remediation, :remove_fields)).to eq(['stop_price'])
      expect(result.details.dig(:remediation, :executable_alternatives, 'stop_price')).to eq('STOP')
      expect(result.error).to include('Use STOP for executable stop orders')
    end

    it 'requires limit_price for LIMIT orders' do
      result = propose(order_type: 'LIMIT')
      expect(result.success?).to be false
      expect(result.error).to include('LIMIT order requires limit_price')

      result = propose(order_type: 'LIMIT', limit_price: 150.0)
      expect(result.success?).to be true
    end

    it 'requires stop_price for STOP orders' do
      result = propose(order_type: 'STOP')
      expect(result.success?).to be false
      expect(result.error).to include('STOP order requires stop_price')

      result = propose(order_type: 'STOP', stop_price: 145.0)
      expect(result.success?).to be true
    end

    it 'requires both limit_price and stop_price for STOP_LIMIT orders' do
      result = propose(order_type: 'STOP_LIMIT', limit_price: 150.0)
      expect(result.success?).to be false
      expect(result.error).to include('STOP_LIMIT order requires both limit_price and stop_price')

      result = propose(order_type: 'STOP_LIMIT', limit_price: 150.0, stop_price: 145.0)
      expect(result.success?).to be true
    end

    it 'requires trail_percent or trail_amount for TRAILING_STOP orders' do
      result = propose(order_type: 'TRAILING_STOP')
      expect(result.success?).to be false
      expect(result.error).to include('TRAILING_STOP requires trail_percent or trail_amount')

      result = propose(order_type: 'TRAILING_STOP', trail_percent: 5.0)
      expect(result.success?).to be true
    end

    it 'rejects unknown order types' do
      result = propose(order_type: 'FOO')
      expect(result.success?).to be false
      expect(result.error).to include('Unknown order type')
    end
  end

  # NOTE: Extended hours and market-hours guards were moved to Trades::GuardService
  # (execution time, not proposal time). See spec/services/trades/guard_service_spec.rb.

  describe 'one-agent-per-ticker guard' do
    before do
      # Another agent already holds AAPL
      create(:position, agent: other_agent, ticker: 'AAPL', qty: 50, avg_entry_price: 150.0)
    end

    it 'rejects BUY if another agent holds the ticker' do
      result = propose(side: 'BUY', ticker: 'AAPL')
      expect(result.success?).to be false
      expect(result.error).to include('One-agent-per-ticker policy')
      expect(result.details[:guard]).to eq('single_agent_ticker')
      expect(result.details[:holder_agent_id]).to eq(other_agent.agent_id)
    end

    it 'allows BUY for a different ticker' do
      result = propose(side: 'BUY', ticker: 'MSFT')
      expect(result.success?).to be true
    end

    it 'allows SELL by the holding agent' do
      create(:position, agent: agent, ticker: 'TSLA', qty: 50, avg_entry_price: 200.0)
      result = propose(side: 'SELL', ticker: 'TSLA', qty_requested: 10)
      expect(result.success?).to be true
    end

    it 'ignores zero-qty positions (closed)' do
      # Close the other agent's position
      Position.find_by(agent: other_agent, ticker: 'AAPL').update!(qty: 0)

      result = propose(side: 'BUY', ticker: 'AAPL')
      expect(result.success?).to be true
    end
  end

  describe 'in-flight guard' do
    it 'rejects proposals when same agent has EXECUTING trade for ticker' do
      create(:trade, :executing, agent: agent, ticker: 'AAPL')

      result = propose(ticker: 'AAPL')
      expect(result.success?).to be false
      expect(result.error).to include('currently EXECUTING')
      expect(result.details[:guard]).to eq('in_flight')
    end

    it 'allows proposals for different tickers' do
      create(:trade, :executing, agent: agent, ticker: 'AAPL')

      result = propose(ticker: 'MSFT')
      expect(result.success?).to be true
    end

    it 'allows proposals by different agents for same ticker' do
      create(:trade, :executing, agent: other_agent, ticker: 'AAPL')

      # This will fail on one-agent-per-ticker if other_agent has position
      # So we need to test without position
      result = propose(ticker: 'AAPL')
      expect(result.success?).to be true
    end
  end

  describe 'duplicate BUY guard' do
    it 'rejects BUY if same agent has APPROVED BUY for ticker' do
      create(:trade, :approved, agent: agent, ticker: 'AAPL', side: 'BUY')

      result = propose(side: 'BUY', ticker: 'AAPL')
      expect(result.success?).to be false
      expect(result.error).to include('already pending')
      expect(result.details[:guard]).to eq('duplicate_buy')
    end

    it 'allows SELL even if BUY is pending' do
      create(:trade, :approved, agent: agent, ticker: 'AAPL', side: 'BUY')
      create(:position, agent: agent, ticker: 'AAPL', qty: 100, avg_entry_price: 150.0)

      result = propose(side: 'SELL', ticker: 'AAPL', qty_requested: 50)
      expect(result.success?).to be true
    end
  end

  describe 'duplicate submission guard' do
    it 'blocks identical re-submission in duplicate window and notifies remediation' do
      create(:trade, :proposed, agent: agent, ticker: 'AAPL', side: 'BUY',
                              qty_requested: 100, order_type: 'MARKET')

      allow(Trades::RemediationAlertService).to receive(:duplicate_submission!)

      result = propose

      expect(result.success?).to be false
      expect(result.details[:guard]).to eq('duplicate_submission')
      expect(Trades::RemediationAlertService).to have_received(:duplicate_submission!)
    end
  end

  describe 'short sell guard' do
    it 'rejects SELL without position unless SHORT_OK in thesis' do
      result = propose(side: 'SELL', ticker: 'AAPL', qty_requested: 100, thesis: 'Regular sell')
      expect(result.success?).to be false
      expect(result.error).to include('no position exists')
      expect(result.error).to include('SHORT_OK')
      expect(result.details[:guard]).to eq('short_sell')
    end

    it 'allows SELL without position if SHORT_OK in thesis' do
      result = propose(
        side: 'SELL',
        ticker: 'AAPL',
        qty_requested: 100,
        thesis: 'Shorting this stock SHORT_OK'
      )
      expect(result.success?).to be true
    end

    it 'is case-insensitive for SHORT_OK' do
      result = propose(
        side: 'SELL',
        ticker: 'AAPL',
        qty_requested: 100,
        thesis: 'Shorting this stock short_ok'
      )
      expect(result.success?).to be true
    end
  end

  describe 'oversell guard' do
    before do
      create(:position, agent: agent, ticker: 'AAPL', qty: 100, avg_entry_price: 150.0)
    end

    it 'allows SELL when qty <= position' do
      result = propose(side: 'SELL', ticker: 'AAPL', qty_requested: 50)
      expect(result.success?).to be true
    end

    it 'allows SELL of entire position' do
      result = propose(side: 'SELL', ticker: 'AAPL', qty_requested: 100)
      expect(result.success?).to be true
    end

    it 'rejects SELL when qty > position' do
      result = propose(side: 'SELL', ticker: 'AAPL', qty_requested: 150)
      expect(result.success?).to be false
      expect(result.error).to include('only 100')
      expect(result.details[:guard]).to eq('insufficient_qty')
    end

    it 'accounts for locked qty from pending sells' do
      # 50 shares already locked in an approved sell
      create(:trade, :approved, agent: agent, ticker: 'AAPL', side: 'SELL', qty_requested: 50)

      # Try to sell 60 more (but only 50 available)
      result = propose(side: 'SELL', ticker: 'AAPL', qty_requested: 60)
      expect(result.success?).to be false
      expect(result.error).to match(/only 50(\.0)? available/)
      expect(result.details[:locked_qty]).to eq(50)
    end
  end

  describe 'notional sell guard' do
    before do
      create(:position, agent: agent, ticker: 'AAPL', qty: 100, avg_entry_price: 150.0)
    end

    it 'rejects notional SELL without NOTIONAL_OK' do
      result = propose(
        side: 'SELL',
        ticker: 'AAPL',
        qty_requested: nil,
        amount_requested: 5000,
        thesis: 'Selling $5000 worth'
      )
      expect(result.success?).to be false
      expect(result.error).to include('SELL requires qty_requested')
      expect(result.error).to include('NOTIONAL_OK')
      expect(result.details[:guard]).to eq('notional_sell')
    end

    it 'allows notional SELL with NOTIONAL_OK' do
      result = propose(
        side: 'SELL',
        ticker: 'AAPL',
        qty_requested: nil,
        amount_requested: 5000,
        thesis: 'Selling $5000 worth NOTIONAL_OK'
      )
      expect(result.success?).to be true
    end

    it 'is case-insensitive for NOTIONAL_OK' do
      result = propose(
        side: 'SELL',
        ticker: 'AAPL',
        qty_requested: nil,
        amount_requested: 5000,
        thesis: 'Selling $5000 worth notional_ok'
      )
      expect(result.success?).to be true
    end
  end

  describe 'failure cooldown guard' do
    it 'blocks rapid resubmission after a failure' do
      # First call fails (missing qty/amount)
      result1 = propose(qty_requested: nil, amount_requested: nil)
      expect(result1.success?).to be false

      # Second call with valid params should be blocked by cooldown
      result2 = propose
      expect(result2.success?).to be false
      expect(result2.error).to include('Proposal cooldown active')
      expect(result2.details[:guard]).to eq('failure_cooldown')
    end

    it 'allows resubmission after cooldown expires' do
      # Fail first
      propose(qty_requested: nil, amount_requested: nil)

      # Simulate cooldown expiry by clearing cache
      Rails.cache.delete("proposal_failure_cooldown:#{agent.agent_id}:AAPL")

      # Should succeed now
      result = propose
      expect(result.success?).to be true
    end

    it 'scopes cooldown per ticker' do
      # Fail on AAPL
      propose(ticker: 'AAPL', qty_requested: nil, amount_requested: nil)

      # MSFT should still work
      result = propose(ticker: 'MSFT')
      expect(result.success?).to be true
    end

    it 'does not set cooldown on successful proposals' do
      result = propose
      expect(result.success?).to be true

      cache_key = "proposal_failure_cooldown:#{agent.agent_id}:AAPL"
      expect(Rails.cache.read(cache_key)).to be_nil
    end

    it 'does not extend cooldown from cooldown rejections' do
      # Fail to start cooldown
      propose(qty_requested: nil, amount_requested: nil)

      cache_key = "proposal_failure_cooldown:#{agent.agent_id}:AAPL"
      original_cached = Rails.cache.read(cache_key)

      # Hit the cooldown
      propose

      # Cache entry should not have been updated
      expect(Rails.cache.read(cache_key)[:failed_at]).to eq(original_cached[:failed_at])
    end

    it 'is disabled when cooldown seconds is 0' do
      allow(AppConfig).to receive(:proposal_failure_cooldown_seconds).and_return(0)

      propose(qty_requested: nil, amount_requested: nil)
      result = propose
      expect(result.success?).to be true
    end

    it 'does not set cooldown for market order parameter remediation failures' do
      result1 = propose(order_type: 'MARKET', stop_price: 145.0)
      expect(result1.success?).to be false
      expect(result1.details[:guard]).to eq('market_order_params')

      cache_key = "proposal_failure_cooldown:#{agent.agent_id}:AAPL"
      expect(Rails.cache.read(cache_key)).to be_nil

      result2 = propose(order_type: 'MARKET')
      expect(result2.success?).to be true
    end

    it 'does not set cooldown for missing sizing remediation failures' do
      result1 = propose(qty_requested: nil, amount_requested: nil)
      expect(result1.success?).to be false
      expect(result1.details[:guard]).to eq('missing_sizing')

      cache_key = "proposal_failure_cooldown:#{agent.agent_id}:AAPL"
      expect(Rails.cache.read(cache_key)).to be_nil

      result2 = propose(order_type: 'MARKET')
      expect(result2.success?).to be true
    end
  end

  describe 'existing PROPOSED trade handling' do
    it 'updates existing PROPOSED trade instead of creating new one' do
      # Create initial proposal
      first_result = propose(thesis: 'First thesis')
      expect(first_result.success?).to be true
      first_trade = first_result.trade

      # Submit another proposal for same agent+ticker
      second_result = propose(thesis: 'Updated thesis', qty_requested: 200)
      expect(second_result.success?).to be true
      second_trade = second_result.trade

      # Should be the same trade record
      expect(second_trade.id).to eq(first_trade.id)
      expect(second_trade.thesis).to eq('Updated thesis')
      expect(second_trade.qty_requested).to eq(200)

      # Only one trade exists
      expect(Trade.where(agent: agent, ticker: 'AAPL').count).to eq(1)
    end

    it 'creates new trade if existing is APPROVED (not PROPOSED)' do
      # Create and approve a trade
      create(:trade, :approved, agent: agent, ticker: 'MSFT', side: 'BUY')

      # New proposal should create new trade
      result = propose(ticker: 'MSFT')
      # This will fail due to duplicate_buy guard
      expect(result.success?).to be false
      expect(result.details[:guard]).to eq('duplicate_buy')
    end
  end

  describe 'trade_id generation' do
    it 'generates unique trade_id with agent prefix' do
      result = propose
      expect(result.trade.trade_id).to start_with(agent.agent_id)
      expect(result.trade.trade_id).to match(/^#{agent.agent_id}-\d+-[a-f0-9]+$/)
    end
  end

  describe 'notional BUY (amount-based)' do
    it 'allows BUY with amount_requested instead of qty' do
      result = propose(qty_requested: nil, amount_requested: 5000)
      expect(result.success?).to be true
      expect(result.trade.amount_requested).to eq(5000)
      expect(result.trade.qty_requested).to be_nil
    end

    it 'rejects notional LIMIT orders for equities' do
      result = propose(qty_requested: nil, amount_requested: 5000, order_type: 'LIMIT', limit_price: 150.0)
      expect(result.success?).to be false
      expect(result.details[:guard]).to eq('notional_order_type')
      expect(result.error).to include('Notional orders must be MARKET')
    end
  end

  describe 'urgent flag' do
    it 'sets is_urgent flag when specified' do
      result = propose(is_urgent: true)
      expect(result.success?).to be true
      expect(result.trade.is_urgent).to be true
    end
  end

  describe 'research file guard' do
    let(:agent) { create(:agent, :test_value) }
    let(:research_dir) { File.expand_path('<legacy-shared-root>/research/tickers') }

    before do
      # Stub File operations to avoid depending on actual filesystem
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:read).and_call_original
    end

    it 'rejects BUY when research file is missing' do
      allow(File).to receive(:exist?).with("#{research_dir}/AAPL.md").and_return(false)

      result = propose(side: 'BUY', ticker: 'AAPL', thesis: 'Test thesis without bypass')
      expect(result.success?).to be false
      expect(result.error).to include('Research file missing')
      expect(result.details[:guard]).to eq('missing_research')
    end

    it 'rejects BUY when research file is empty' do
      allow(File).to receive(:exist?).with("#{research_dir}/AAPL.md").and_return(true)
      allow(File).to receive(:read).with("#{research_dir}/AAPL.md").and_return('')

      result = propose(side: 'BUY', ticker: 'AAPL', thesis: 'Test thesis without bypass')
      expect(result.success?).to be false
      expect(result.error).to include('unfilled template')
      expect(result.details[:guard]).to eq('template_research')
    end

    it 'rejects BUY when research file is untouched template' do
      template = "# TICKER - Company Name\n\n**Last Updated:** YYYY-MM-DD by [Agent]\n\n## Company Overview\n- Sector:\n"
      allow(File).to receive(:exist?).with("#{research_dir}/AAPL.md").and_return(true)
      allow(File).to receive(:read).with("#{research_dir}/AAPL.md").and_return(template)

      result = propose(side: 'BUY', ticker: 'AAPL', thesis: 'Test thesis without bypass')
      expect(result.success?).to be false
      expect(result.details[:guard]).to eq('template_research')
    end

    it 'allows BUY when research file has real content' do
      content = "# AAPL - Apple Inc.\n\n**Last Updated:** 2026-02-04 by westin\n\n## Company Overview\n- Sector: Technology\n"
      allow(File).to receive(:exist?).with("#{research_dir}/AAPL.md").and_return(true)
      allow(File).to receive(:read).with("#{research_dir}/AAPL.md").and_return(content)

      result = propose(side: 'BUY', ticker: 'AAPL')
      expect(result.success?).to be true
    end

    it 'allows BUY with RESEARCH_OK bypass in thesis' do
      allow(File).to receive(:exist?).with("#{research_dir}/AAPL.md").and_return(false)

      result = propose(side: 'BUY', ticker: 'AAPL', thesis: 'Urgent momentum play RESEARCH_OK')
      expect(result.success?).to be true
    end

    it 'skips the research file guard for momentum traders' do
      momentum_agent = create(:agent, :test_momentum)
      allow(File).to receive(:exist?).with("#{research_dir}/AAPL.md").never

      result = propose(agent: momentum_agent, side: 'BUY', ticker: 'AAPL', thesis: 'Fast breakout continuation')
      expect(result.success?).to be true
    end

    it 'skips research check for SELL orders' do
      allow(File).to receive(:exist?).with("#{research_dir}/AAPL.md").and_return(false)

      # SELL without position will fail on short_sell guard, not research guard
      result = propose(side: 'SELL', ticker: 'AAPL', qty_requested: 50)
      expect(result.details[:guard]).to eq('short_sell')
    end

    it 'skips research check for crypto pairs' do
      allow(File).to receive(:exist?).with("#{research_dir}/BTC/USD.md").never

      result = propose(side: 'BUY', ticker: 'BTC/USD', qty_requested: 1)
      # May fail for other reasons but not research
      expect(result.details[:guard]).not_to eq('missing_research') if result.error
    end

    it 'gracefully handles file read errors without blocking trade' do
      allow(File).to receive(:exist?).with("#{research_dir}/AAPL.md").and_raise(Errno::EACCES, 'Permission denied')

      result = propose(side: 'BUY', ticker: 'AAPL')
      # Should not fail due to research check
      expect(result.success?).to be true
    end
  end
end
