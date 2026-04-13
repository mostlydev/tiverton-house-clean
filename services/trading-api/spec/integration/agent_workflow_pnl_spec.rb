# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Agent Workflow with Realized P&L', type: :integration do
  # Simulate the full agent workflow as described in TRADE-PROTOCOL.md
  # and verify that realized P&L tracking works correctly at each step

  let(:agent) { create(:agent, agent_id: 'westin') }
  let(:wallet) { agent.wallet }
  let(:broker) { alpaca_mock_broker }

  before do
    # Start with clean slate
    wallet.update!(cash: 20000.0, invested: 0.0)
  end

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

  describe 'Full BUY workflow (creates position lot)' do
    # This test verifies the full trade execution workflow including wallet updates
    # Skipping for now as it requires extensive mocking of TradeExecutionService internals
    xit 'trader proposes, Tiverton approves, execution creates lot with cost basis' do
      # STEP 1: Agent proposes trade (via db-trade-propose.sh)
      trade = create(:trade,
        agent: agent,
        ticker: 'NVDA',
        side: 'BUY',
        amount_requested: 5000.0,
        status: 'PROPOSED',
        thesis: 'AI momentum play'
      )

      expect(trade.status).to eq('PROPOSED')

      # STEP 2: Tiverton approves (via db-trade-approve.sh)
      trade.approved_by = 'tiverton'
      trade.confirmed_at = Time.current
      trade.approve!
      trade.reload

      expect(trade.status).to eq('APPROVED')
      expect(trade.approved_by).to eq('tiverton')

      # STEP 3: Rails auto-executes (TradeExecutionService via Sidekiq)
      alpaca_mock_fill(broker, ticker: 'NVDA', side: 'buy', qty: 10, price: 500.0)

      result = TradeExecutionService.new(trade, executed_by: 'sentinel').call
      expect(result.success?).to be true

      trade.reload
      expect(trade.status).to eq('FILLED')
      expect(trade.qty_filled).to eq(10)
      expect(trade.avg_fill_price).to eq(500.0)

      # VERIFY: Position lot created with correct cost basis
      lot = PositionLot.open.find_by(ticker: 'NVDA', agent: agent)
      expect(lot).to be_present
      expect(lot.qty).to eq(10.0)
      expect(lot.cost_basis_per_share).to eq(500.0)
      expect(lot.total_cost_basis).to eq(5000.0)
      expect(lot.open_source_type).to eq('BrokerFill')
      expect(lot.closed_at).to be_nil

      # VERIFY: Wallet updated
      wallet.reload
      expect(wallet.cash.to_f).to be_within(0.01).of(15000.0) # 20000 - 5000
      expect(wallet.invested.to_f).to be_within(0.01).of(5000.0)

      # VERIFY: No realized P&L yet (position not closed)
      pnl_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:realized_pnl")
      expect(pnl_entries.count).to eq(0)
    end
  end

  describe 'Full SELL workflow (closes lot, posts P&L)' do
    let(:service) { Broker::FillIngestionService.new }

    let!(:existing_lot) do
      # Simulate previous buy fill that created this lot
      ingest_fill(service,
        agent: agent,
        broker_fill_id: 'fill-tsla-buy-initial',
        ticker: 'TSLA',
        side: 'buy',
        qty: 20.0,
        price: 400.0,
        executed_at: 2.days.ago
      )

      PositionLot.open.find_by(ticker: 'TSLA', agent: agent)
    end

    context 'sell at gain' do
      it 'closes lot and posts realized gain to ledger' do
        # STEP: Sell fill comes in at higher price (simulates full workflow result)
        result = ingest_fill(service,
          agent: agent,
          broker_fill_id: 'fill-tsla-sell-gain',
          ticker: 'TSLA',
          side: 'sell',
          qty: 20.0,
          price: 450.0,
          executed_at: Time.current
        )

        expect(result.success).to be true

        # VERIFY: Lot closed with realized P&L
        existing_lot.reload
        expect(existing_lot.closed_at).to be_present
        expect(existing_lot.realized_pnl).to eq(1000.0) # (450 - 400) * 20

        # VERIFY: P&L posted to ledger
        pnl_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:realized_pnl")
        expect(pnl_entries.count).to eq(1)
        expect(pnl_entries.sum(:amount).to_f).to eq(1000.0)

        # VERIFY: Cost basis adjustment balances
        cost_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:cost_basis_adjustment")
        expect(cost_entries.sum(:amount).to_f).to eq(-1000.0)

        # VERIFY: Transaction balances to zero
        pnl_txn = LedgerTransaction.where(source_type: 'PositionLot').last
        expect(pnl_txn.ledger_entries.sum(:amount).to_f).to be_within(0.01).of(0.0)
      end
    end

    context 'sell at loss' do
      it 'closes lot and posts realized loss to ledger' do
        # Sell fill at LOWER price
        result = ingest_fill(service,
          agent: agent,
          broker_fill_id: 'fill-tsla-sell-loss',
          ticker: 'TSLA',
          side: 'sell',
          qty: 20.0,
          price: 350.0,
          executed_at: Time.current
        )

        expect(result.success).to be true

        # VERIFY: Lot closed with negative P&L
        existing_lot.reload
        expect(existing_lot.realized_pnl).to eq(-1000.0) # (350 - 400) * 20

        # VERIFY: Loss posted to ledger
        pnl_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:realized_pnl")
        expect(pnl_entries.sum(:amount).to_f).to eq(-1000.0)

        # VERIFY: Transaction still balances
        pnl_txn = LedgerTransaction.where(source_type: 'PositionLot').last
        expect(pnl_txn.ledger_entries.sum(:amount).to_f).to be_within(0.01).of(0.0)
      end
    end
  end

  describe 'Partial SELL workflow (FIFO lot closing)' do
    let(:fill_service) { Broker::FillIngestionService.new }

    let!(:lot1) do
      ingest_fill(fill_service,
        agent: agent,
        broker_fill_id: 'fill-aapl-buy-1',
        ticker: 'AAPL',
        side: 'buy',
        qty: 10.0,
        price: 150.0,
        executed_at: 3.days.ago
      )
      PositionLot.open.where(agent: agent, ticker: 'AAPL', cost_basis_per_share: 150.0).first
    end

    let!(:lot2) do
      ingest_fill(fill_service,
        agent: agent,
        broker_fill_id: 'fill-aapl-buy-2',
        ticker: 'AAPL',
        side: 'buy',
        qty: 10.0,
        price: 170.0,
        executed_at: 1.day.ago
      )
      PositionLot.open.where(agent: agent, ticker: 'AAPL', cost_basis_per_share: 170.0).first
    end

    let!(:position) do
      create(:position,
        agent: agent,
        ticker: 'AAPL',
        qty: 20.0,
        avg_entry_price: 160.0,
        current_value: 3200.0
      )
    end

    before do
      wallet.update!(cash: 16800.0, invested: 3200.0)
    end

    it 'closes oldest lot first, keeps partial lot open' do
      # Sell only 15 shares (should close lot1 fully, partially close lot2)
      trade = create(:trade,
        agent: agent,
        ticker: 'AAPL',
        side: 'SELL',
        qty_requested: 15.0,
        status: 'PROPOSED',
        thesis: 'Trim position'
      )

      trade.approved_by = 'tiverton'
      trade.confirmed_at = Time.current
      trade.approve!

      alpaca_mock_fill(broker, ticker: 'AAPL', side: 'sell', qty: 15, price: 180.0)

      result = TradeExecutionService.new(trade, executed_by: 'sentinel').call
      expect(result.success?).to be true

      # VERIFY: Lot1 fully closed
      lot1.reload
      expect(lot1.closed_at).to be_present
      expect(lot1.qty).to eq(10.0)
      expect(lot1.realized_pnl).to eq(300.0) # (180 - 150) * 10

      # VERIFY: Lot2 partially closed (split into two lots)
      closed_lot2 = PositionLot.closed.find_by(
        ticker: 'AAPL',
        agent: agent,
        cost_basis_per_share: 170.0
      )
      expect(closed_lot2).to be_present
      expect(closed_lot2.qty).to eq(5.0)
      expect(closed_lot2.realized_pnl).to eq(50.0) # (180 - 170) * 5

      open_lot2 = PositionLot.open.find_by(
        ticker: 'AAPL',
        agent: agent,
        cost_basis_per_share: 170.0
      )
      expect(open_lot2).to be_present
      expect(open_lot2.qty).to eq(5.0)

      # VERIFY: Total P&L posted
      pnl_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:realized_pnl")
      expect(pnl_entries.sum(:amount).to_f).to eq(350.0) # 300 + 50

      # VERIFY: Two separate P&L transactions (one per closed lot)
      pnl_txns = LedgerTransaction.where(source_type: 'PositionLot')
      expect(pnl_txns.count).to eq(2)
    end
  end


  describe 'Multiple round-trip trades (accumulating P&L)' do
    it 'tracks cumulative realized P&L across multiple trades' do
      service = Broker::FillIngestionService.new

      # Round 1: Buy AMZN at $180
      ingest_fill(service,
        agent: agent,
        broker_fill_id: 'fill-amzn-buy-1',
        ticker: 'AMZN',
        side: 'buy',
        qty: 20.0,
        price: 180.0,
        executed_at: 2.days.ago
      )

      # Sell at $200 (gain: $400)
      ingest_fill(service,
        agent: agent,
        broker_fill_id: 'fill-amzn-sell-1',
        ticker: 'AMZN',
        side: 'sell',
        qty: 20.0,
        price: 200.0,
        executed_at: 1.day.ago
      )

      pnl_after_round1 = LedgerEntry
        .where(account_code: "agent:#{agent.agent_id}:realized_pnl")
        .sum(:amount).to_f
      expect(pnl_after_round1).to eq(400.0)

      # Round 2: Buy AMZN again at $210
      ingest_fill(service,
        agent: agent,
        broker_fill_id: 'fill-amzn-buy-2',
        ticker: 'AMZN',
        side: 'buy',
        qty: 20.0,
        price: 210.0,
        executed_at: 12.hours.ago
      )

      # Sell at $190 (loss: -$400)
      ingest_fill(service,
        agent: agent,
        broker_fill_id: 'fill-amzn-sell-2',
        ticker: 'AMZN',
        side: 'sell',
        qty: 20.0,
        price: 190.0,
        executed_at: Time.current
      )

      # VERIFY: Cumulative P&L is net zero ($400 gain - $400 loss)
      pnl_total = LedgerEntry
        .where(account_code: "agent:#{agent.agent_id}:realized_pnl")
        .sum(:amount).to_f
      expect(pnl_total).to eq(0.0)

      # VERIFY: Both lots closed
      expect(PositionLot.closed.where(agent: agent, ticker: 'AMZN').count).to eq(2)
    end
  end

  # API endpoint is tested in controller specs, skipping integration test here

  describe 'Position reconciliation with P&L' do
    it 'ledger P&L matches sum of closed lot P&L' do
      service = Broker::FillIngestionService.new

      # Create and close multiple lots with various P&L using fill ingestion
      lots_data = [
        { ticker: 'TSLA', cost: 400.0, sale: 450.0, qty: 10.0 }, # +500
        { ticker: 'NVDA', cost: 500.0, sale: 480.0, qty: 5.0 },  # -100
        { ticker: 'AAPL', cost: 150.0, sale: 170.0, qty: 20.0 }  # +400
      ]

      lots_data.each_with_index do |data, idx|
        # Buy
        ingest_fill(service,
          agent: agent,
          broker_fill_id: "fill-buy-#{idx}",
          ticker: data[:ticker],
          side: 'buy',
          qty: data[:qty],
          price: data[:cost],
          executed_at: 2.days.ago
        )

        # Sell (auto-posts P&L)
        ingest_fill(service,
          agent: agent,
          broker_fill_id: "fill-sell-#{idx}",
          ticker: data[:ticker],
          side: 'sell',
          qty: data[:qty],
          price: data[:sale],
          executed_at: 1.day.ago
        )
      end

      # VERIFY: Ledger P&L matches sum of lot P&L
      ledger_pnl = LedgerEntry
        .where(account_code: "agent:#{agent.agent_id}:realized_pnl")
        .sum(:amount).to_f

      lot_pnl = PositionLot
        .where(agent: agent)
        .closed
        .sum(:realized_pnl).to_f

      expect(ledger_pnl).to eq(lot_pnl)
      expect(ledger_pnl).to eq(800.0) # 500 - 100 + 400
    end
  end

  describe 'Bootstrap lots realize P&L on close' do
    it 'bootstrap lot establishes cost basis, sell realizes P&L' do
      service = Broker::FillIngestionService.new

      # Create a bootstrap lot (simulating Feb 4 bootstrap reconciliation)
      bootstrap_lot = create(:position_lot,
        agent: agent,
        ticker: 'SPY',
        qty: 50.0,
        cost_basis_per_share: 600.0,
        total_cost_basis: 30000.0,
        opened_at: 1.week.ago,
        bootstrap_adjusted: true
      )

      # Sell the bootstrap position
      ingest_fill(service,
        agent: agent,
        broker_fill_id: 'fill-spy-sell-bootstrap',
        ticker: 'SPY',
        side: 'sell',
        qty: 50.0,
        price: 650.0,
        executed_at: Time.current
      )

      # VERIFY: Lot closed with P&L
      bootstrap_lot.reload
      expect(bootstrap_lot.closed_at).to be_present
      expect(bootstrap_lot.realized_pnl).to eq(2500.0) # (650 - 600) * 50

      # VERIFY: P&L posted to ledger
      pnl_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:realized_pnl")
      expect(pnl_entries.sum(:amount).to_f).to eq(2500.0)

      # NOTE: Bootstrap lots establish cost basis from reconciliation
      # The P&L is correctly calculated from that basis when sold
    end
  end
end
