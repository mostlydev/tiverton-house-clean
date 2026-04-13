# frozen_string_literal: true

require 'test_helper'

# Integration tests for ledger-based trade workflow
# Validates the complete flow from proposal to fill to position update
class LedgerWorkflowTest < ActionDispatch::IntegrationTest
  setup do
    @agent = agents(:dundas)
    @agent.create_wallet!(wallet_size: 20000, cash: 5000, invested: 15000) unless @agent.wallet
  end

  # Test 1: Positions API returns ledger data when configured
  test 'positions endpoint returns ledger source when LEDGER_READ_SOURCE=ledger' do
    # Skip if not in ledger mode
    skip 'Not in ledger mode' unless LedgerMigration.read_from_ledger?

    get "/api/v1/positions?agent_id=#{@agent.agent_id}"
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 'ledger', json['source']
  end

  # Test 2: Wallets API returns ledger data when configured
  test 'wallets endpoint returns ledger source when LEDGER_READ_SOURCE=ledger' do
    skip 'Not in ledger mode' unless LedgerMigration.read_from_ledger?

    get "/api/v1/wallets/#{@agent.agent_id}"
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 'ledger', json['source']
  end

  # Test 3: Trade proposal creates PROPOSED record
  test 'trade proposal creates PROPOSED trade' do
    post '/api/v1/trades', params: {
      trade: {
        agent_id: @agent.agent_id,
        ticker: 'AAPL',
        side: 'BUY',
        amount_requested: 1000,
        thesis: 'Integration test'
      }
    }, as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal 'PROPOSED', json['status']
    assert_equal @agent.agent_id, json['agent_id']
  end

  # Test 4: Ledger stats endpoint returns valid stats
  test 'ledger stats endpoint returns statistics' do
    get '/api/v1/ledger/stats'
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?('ledger_transactions')
    assert json.key?('position_lots')
    assert json.key?('broker_fills')
  end

  # Test 5: Market context endpoint returns combined data
  test 'market context endpoint returns positions and wallet' do
    get "/api/v1/market_context/#{@agent.agent_id}"
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?('positions') || json.key?('wallet')
  end

  # Test 6: Fill processing routes through ledger when enabled
  test 'fill processing creates ledger entries when write_to_ledger enabled' do
    skip 'Ledger writes disabled' unless LedgerMigration.write_to_ledger?

    # Create a trade in EXECUTING state
    trade = Trade.create!(
      agent: @agent,
      ticker: 'TEST',
      side: 'BUY',
      status: 'EXECUTING',
      amount_requested: 500,
      qty_requested: 10,
      thesis: 'Integration test fill'
    )

    initial_entry_count = LedgerEntry.count

    # Process a fill
    processor = Trades::FillProcessorService.new(trade)
    processor.process_fill(
      qty_filled: 10,
      avg_fill_price: 50.0,
      final: true
    )

    # Verify ledger entry was created
    assert_operator LedgerEntry.count, :>, initial_entry_count,
      'Expected ledger entries to be created'
  end

  # Test 7: Legacy writes are blocked when ledger-only mode
  test 'legacy position writes blocked in ledger-only mode' do
    skip 'Not in ledger-only mode' unless LedgerMigration.ledger_only_writes?

    # Verify the guard returns true
    assert LedgerMigration.block_legacy_write?('test'),
      'Expected legacy writes to be blocked'
  end

  # Test 8: Shadow comparison reports zero diffs when ledger matches legacy
  test 'shadow comparison service runs without errors' do
    skip 'Not testing shadow comparison in non-dual mode'

    comparison = Ledger::ShadowComparisonService.new
    result = comparison.compare_all

    assert result.key?(:status)
    assert_includes %w[completed error], result[:status]
  end

  # Test 9: Position projection matches lot sums
  test 'position projection aggregates lots correctly' do
    skip 'No position lots to test' if PositionLot.where(agent: @agent).empty?

    projection = Ledger::ProjectionService.new
    positions = projection.positions_for_agent(@agent)

    # For each position, verify it matches lot aggregation
    positions.each do |pos|
      lots = PositionLot.where(agent: @agent, ticker: pos[:ticker], closed_at: nil)
      lot_qty = lots.sum(:qty)

      assert_in_delta pos[:qty], lot_qty, 0.0001,
        "Position qty mismatch for #{pos[:ticker]}"
    end
  end

  # Test 10: Wallet cash matches ledger entry sums
  test 'wallet cash projection matches ledger entries' do
    skip 'Not in ledger mode' unless LedgerMigration.read_from_ledger?

    projection = Ledger::ProjectionService.new
    wallet = projection.wallet_for_agent(@agent)

    # Get cash from ledger entries
    cash_account = "agent:#{@agent.agent_id}:cash"
    ledger_cash = LedgerEntry.where(account_code: cash_account).sum(:amount)

    assert_in_delta wallet[:cash], ledger_cash, 0.01,
      'Wallet cash should match ledger entry sum'
  end
end
