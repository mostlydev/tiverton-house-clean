# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Broker::FillIngestionService, type: :service do
  include ExternalServicesMock

  let(:service) { described_class.new }
  let(:agent) { create(:agent, agent_id: 'test-trader') }
  let(:ticker) { 'AAPL' }

  before do
    mock_all_external_services!
    # System agent needed for stub broker order creation during fill ingestion
    create(:agent, agent_id: 'system', name: 'System') unless Agent.exists?(agent_id: 'system')
  end

  describe 'realized P&L posting' do
    context 'when selling position with gain' do
      before do
        # Create initial buy fill and lot
        service.ingest!(
          broker_fill_id: 'fill-buy-1',
          broker_order_id: 'order-buy-1',
          ticker: ticker,
          side: 'buy',
          qty: 10.0,
          price: 100.0,
          executed_at: 2.days.ago,
          agent: agent
        )
      end

      it 'posts realized gain to ledger' do
        # Sell at higher price
        result = service.ingest!(
          broker_fill_id: 'fill-sell-1',
          broker_order_id: 'order-sell-1',
          ticker: ticker,
          side: 'sell',
          qty: 10.0,
          price: 150.0,
          executed_at: Time.current,
          agent: agent
        )

        expect(result.success).to be true

        # Check that lot was closed with realized P&L
        closed_lot = PositionLot.closed.last
        expect(closed_lot.realized_pnl).to eq(500.0) # (150 - 100) * 10

        # Check ledger entries
        pnl_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:realized_pnl")
        expect(pnl_entries.count).to eq(1)
        expect(pnl_entries.sum(:amount).to_f).to eq(500.0)

        # Check cost basis adjustment
        cost_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:cost_basis_adjustment")
        expect(cost_entries.count).to eq(1)
        expect(cost_entries.sum(:amount).to_f).to eq(-500.0)

        # Check that P&L transaction balances
        pnl_txn = LedgerTransaction.where(source_type: 'PositionLot').last
        expect(pnl_txn.ledger_entries.sum(:amount).to_f).to be_within(0.01).of(0.0)
      end

      it 'sets correct transaction description' do
        service.ingest!(
          broker_fill_id: 'fill-sell-2',
          broker_order_id: 'order-sell-2',
          ticker: ticker,
          side: 'sell',
          qty: 10.0,
          price: 150.0,
          executed_at: Time.current,
          agent: agent
        )

        pnl_txn = LedgerTransaction.where(source_type: 'PositionLot').last
        expect(pnl_txn.description).to include('Realized gain')
        expect(pnl_txn.description).to include(ticker)
      end
    end

    context 'when selling position with loss' do
      before do
        # Create initial buy fill and lot
        service.ingest!(
          broker_fill_id: 'fill-buy-2',
          broker_order_id: 'order-buy-2',
          ticker: ticker,
          side: 'buy',
          qty: 5.0,
          price: 400.0,
          executed_at: 2.days.ago,
          agent: agent
        )
      end

      it 'posts realized loss to ledger' do
        # Sell at lower price
        result = service.ingest!(
          broker_fill_id: 'fill-sell-3',
          broker_order_id: 'order-sell-3',
          ticker: ticker,
          side: 'sell',
          qty: 5.0,
          price: 350.0,
          executed_at: Time.current,
          agent: agent
        )

        expect(result.success).to be true

        # Check that lot was closed with realized P&L
        closed_lot = PositionLot.closed.last
        expect(closed_lot.realized_pnl).to eq(-250.0) # (350 - 400) * 5

        # Check ledger entries
        pnl_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:realized_pnl")
        expect(pnl_entries.sum(:amount).to_f).to eq(-250.0)

        # Check transaction description mentions loss
        pnl_txn = LedgerTransaction.where(source_type: 'PositionLot').last
        expect(pnl_txn.description).to include('Realized loss')
      end
    end

    context 'when selling partial position' do
      before do
        # Create initial buy fill and lot
        service.ingest!(
          broker_fill_id: 'fill-buy-3',
          broker_order_id: 'order-buy-3',
          ticker: ticker,
          side: 'buy',
          qty: 20.0,
          price: 100.0,
          executed_at: 2.days.ago,
          agent: agent
        )
      end

      it 'posts proportional P&L for partial close' do
        # Sell half the position
        result = service.ingest!(
          broker_fill_id: 'fill-sell-4',
          broker_order_id: 'order-sell-4',
          ticker: ticker,
          side: 'sell',
          qty: 10.0,
          price: 150.0,
          executed_at: Time.current,
          agent: agent
        )

        expect(result.success).to be true

        # Check that partial lot was closed
        closed_lot = PositionLot.closed.last
        expect(closed_lot.qty).to eq(10.0)
        expect(closed_lot.realized_pnl).to eq(500.0) # (150 - 100) * 10

        # Check that open lot remains
        open_lot = PositionLot.open.where(ticker: ticker, agent: agent).first
        expect(open_lot.qty).to eq(10.0)

        # Check P&L posting
        pnl_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:realized_pnl")
        expect(pnl_entries.sum(:amount).to_f).to eq(500.0)
      end
    end

    context 'when closing multiple lots (FIFO)' do
      before do
        # Create two buy lots at different prices
        service.ingest!(
          broker_fill_id: 'fill-buy-4',
          broker_order_id: 'order-buy-4',
          ticker: ticker,
          side: 'buy',
          qty: 5.0,
          price: 100.0,
          executed_at: 3.days.ago,
          agent: agent
        )

        service.ingest!(
          broker_fill_id: 'fill-buy-5',
          broker_order_id: 'order-buy-5',
          ticker: ticker,
          side: 'buy',
          qty: 5.0,
          price: 120.0,
          executed_at: 2.days.ago,
          agent: agent
        )
      end

      it 'closes oldest lot first and posts separate P&L entries' do
        # Sell entire position
        result = service.ingest!(
          broker_fill_id: 'fill-sell-5',
          broker_order_id: 'order-sell-5',
          ticker: ticker,
          side: 'sell',
          qty: 10.0,
          price: 150.0,
          executed_at: Time.current,
          agent: agent
        )

        expect(result.success).to be true

        # Check that both lots are closed
        closed_lots = PositionLot.closed.where(ticker: ticker, agent: agent).order(:opened_at)
        expect(closed_lots.count).to eq(2)

        # First lot (oldest, at $100)
        expect(closed_lots.first.realized_pnl).to eq(250.0) # (150 - 100) * 5

        # Second lot (at $120)
        expect(closed_lots.second.realized_pnl).to eq(150.0) # (150 - 120) * 5

        # Check total P&L posted
        pnl_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:realized_pnl")
        expect(pnl_entries.sum(:amount).to_f).to eq(400.0) # 250 + 150

        # Check that two separate P&L transactions were created
        pnl_txns = LedgerTransaction.where(source_type: 'PositionLot')
        expect(pnl_txns.count).to eq(2)
      end
    end

    context 'when P&L posting is disabled via feature flag' do
      around do |example|
        original_value = ENV['LEDGER_SKIP_PNL_POSTING']
        ENV['LEDGER_SKIP_PNL_POSTING'] = 'true'
        example.run
        ENV['LEDGER_SKIP_PNL_POSTING'] = original_value
      end

      before do
        # Create initial buy fill and lot
        service.ingest!(
          broker_fill_id: 'fill-buy-6',
          broker_order_id: 'order-buy-6',
          ticker: ticker,
          side: 'buy',
          qty: 10.0,
          price: 100.0,
          executed_at: 2.days.ago,
          agent: agent
        )
      end

      it 'does not post P&L to ledger' do
        # Sell at higher price
        result = service.ingest!(
          broker_fill_id: 'fill-sell-6',
          broker_order_id: 'order-sell-6',
          ticker: ticker,
          side: 'sell',
          qty: 10.0,
          price: 150.0,
          executed_at: Time.current,
          agent: agent
        )

        expect(result.success).to be true

        # Check that lot was still closed with realized P&L calculated
        closed_lot = PositionLot.closed.last
        expect(closed_lot.realized_pnl).to eq(500.0)

        # Check that NO ledger entries were created for P&L
        pnl_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:realized_pnl")
        expect(pnl_entries.count).to eq(0)

        pnl_txns = LedgerTransaction.where(source_type: 'PositionLot')
        expect(pnl_txns.count).to eq(0)
      end
    end

    context 'when P&L is zero' do
      before do
        # Create initial buy fill and lot
        service.ingest!(
          broker_fill_id: 'fill-buy-7',
          broker_order_id: 'order-buy-7',
          ticker: ticker,
          side: 'buy',
          qty: 10.0,
          price: 100.0,
          executed_at: 2.days.ago,
          agent: agent
        )
      end

      it 'does not post zero P&L to ledger' do
        # Sell at same price
        result = service.ingest!(
          broker_fill_id: 'fill-sell-7',
          broker_order_id: 'order-sell-7',
          ticker: ticker,
          side: 'sell',
          qty: 10.0,
          price: 100.0,
          executed_at: Time.current,
          agent: agent
        )

        expect(result.success).to be true

        # Check that lot was closed with zero P&L
        closed_lot = PositionLot.closed.last
        expect(closed_lot.realized_pnl).to eq(0.0)

        # Check that NO ledger entries were created for zero P&L
        pnl_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:realized_pnl")
        expect(pnl_entries.count).to eq(0)
      end
    end

    context 'ledger balance validation' do
      before do
        # Create initial buy fill and lot
        service.ingest!(
          broker_fill_id: 'fill-buy-8',
          broker_order_id: 'order-buy-8',
          ticker: ticker,
          side: 'buy',
          qty: 10.0,
          price: 100.0,
          executed_at: 2.days.ago,
          agent: agent
        )
      end

      it 'ensures all P&L transactions balance to zero' do
        # Sell at higher price
        service.ingest!(
          broker_fill_id: 'fill-sell-8',
          broker_order_id: 'order-sell-8',
          ticker: ticker,
          side: 'sell',
          qty: 10.0,
          price: 150.0,
          executed_at: Time.current,
          agent: agent
        )

        # Check that all P&L transactions balance
        LedgerTransaction.where(source_type: 'PositionLot').each do |txn|
          balance = txn.ledger_entries.sum(:amount)
          expect(balance.abs).to be < 0.01
        end
      end
    end

    context 'when P&L posting fails' do
      before do
        # Create initial buy fill and lot
        service.ingest!(
          broker_fill_id: 'fill-buy-9',
          broker_order_id: 'order-buy-9',
          ticker: ticker,
          side: 'buy',
          qty: 10.0,
          price: 100.0,
          executed_at: 2.days.ago,
          agent: agent
        )
      end

      it 'does not fail entire fill ingestion' do
        # Mock Ledger::PostingService to fail when posting P&L
        allow_any_instance_of(Ledger::PostingService).to receive(:post!).and_wrap_original do |method, *args|
          # Only fail for PositionLot postings (P&L), not BrokerFill postings
          if method.receiver.instance_variable_get(:@source_type) == 'PositionLot'
            raise StandardError, 'Ledger posting test error'
          else
            method.call(*args)
          end
        end

        # Sell should still succeed even if P&L posting fails (error caught in rescue block)
        result = service.ingest!(
          broker_fill_id: 'fill-sell-9',
          broker_order_id: 'order-sell-9',
          ticker: ticker,
          side: 'sell',
          qty: 10.0,
          price: 150.0,
          executed_at: Time.current,
          agent: agent
        )

        expect(result.success).to be true

        # Fill and lot should still be created
        expect(BrokerFill.find_by(broker_fill_id: 'fill-sell-9')).to be_present
        closed_lot = PositionLot.closed.last
        expect(closed_lot.realized_pnl).to eq(500.0)

        # P&L should NOT be posted (due to error)
        pnl_entries = LedgerEntry.where(account_code: "agent:#{agent.agent_id}:realized_pnl")
        expect(pnl_entries.count).to eq(0)
      end
    end
  end
end
