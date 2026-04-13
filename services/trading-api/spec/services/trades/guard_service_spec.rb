require 'rails_helper'

RSpec.describe Trades::GuardService, type: :service do
  let(:agent) { create(:agent, :westin) }
  let(:guard_service) { described_class.new(trade) }

  before do
    # Mock market as open during regular hours so market-hours guard doesn't interfere
    mock_session = instance_double(MarketSessionService, session: :regular, regular?: true, extended?: false, closed?: false)
    allow(MarketSessionService).to receive(:current).and_return(mock_session)

    # Create a fresh broker account snapshot so cash checks use wallet balance
    BrokerAccountSnapshot.create!(
      broker: 'alpaca',
      cash: agent.wallet.cash,
      buying_power: agent.wallet.cash,
      equity: agent.wallet.cash,
      fetched_at: Time.current
    )

    # Prevent refresh from hitting real Alpaca API
    allow(BrokerAccountSnapshotService).to receive(:new).and_return(
      instance_double(BrokerAccountSnapshotService, call: { success: false, error: 'mocked' })
    )

    # Mock broker quote for BUY price lookups (MARKET orders without limit_price)
    allow(Alpaca::BrokerService).to receive(:new).and_return(
      instance_double(Alpaca::BrokerService, get_quote: { success: true, price: 150.0 })
    )
  end

  describe '#validate_execution!' do
    context 'when SELL without position' do
      let(:trade) { create(:trade, :approved, :sell, agent: agent, ticker: 'AAPL', qty_requested: 10, thesis: 'Test sell') }

      it 'raises ValidationError without SHORT_OK' do
        expect { guard_service.validate_execution! }.to raise_error(
          Trades::GuardService::ValidationError,
          /Cannot SELL AAPL - no position exists/
        )
      end

      it 'allows sell with SHORT_OK flag' do
        trade.update!(thesis: "Test sell\nSHORT_OK")
        expect { guard_service.validate_execution! }.not_to raise_error
      end

      it 'allows sell with existing position' do
        create(:position, agent: agent, ticker: 'AAPL', qty: 100)
        expect { guard_service.validate_execution! }.not_to raise_error
      end
    end

    context 'when notional SELL' do
      let(:trade) do
        create(:trade, :approved, :sell, :notional, agent: agent, ticker: 'AAPL', thesis: 'Test sell')
      end

      before do
        # Create position so SHORT_OK check passes
        create(:position, agent: agent, ticker: 'AAPL', qty: 100)
      end

      it 'raises ValidationError without NOTIONAL_OK' do
        expect { guard_service.validate_execution! }.to raise_error(
          Trades::GuardService::ValidationError,
          /Notional SELL not allowed/
        )
      end

      it 'allows notional sell with NOTIONAL_OK flag' do
        trade.update!(thesis: "Test sell\nNOTIONAL_OK")
        expect { guard_service.validate_execution! }.not_to raise_error
      end
    end

    context 'when notional BUY with LIMIT' do
      let(:trade) do
        create(:trade, :approved, agent: agent, ticker: 'AAPL', qty_requested: nil,
               amount_requested: 5000.0, order_type: 'LIMIT', limit_price: 150.0)
      end

      it 'raises ValidationError for notional non-market orders' do
        expect { guard_service.validate_execution! }.to raise_error(
          Trades::GuardService::ValidationError,
          /Notional orders must be MARKET/
        )
      end
    end

    context 'when checking sufficient position' do
      let(:trade) { create(:trade, :approved, :sell, agent: agent, ticker: 'AAPL', qty_requested: 150) }

      before do
        create(:position, agent: agent, ticker: 'AAPL', qty: 100)
      end

      it 'raises ValidationError when qty exceeds position' do
        expect { guard_service.validate_execution! }.to raise_error(
          Trades::GuardService::ValidationError,
          /Cannot SELL 150(\.0)? AAPL - only .* available/
        )
      end

      it 'accounts for locked qty in pending trades' do
        # Create pending sell that locks 50 shares
        create(:trade, :approved, :sell, agent: agent, ticker: 'AAPL', qty_requested: 50)

        # Now only 50 available (100 - 50 locked)
        trade.update!(qty_requested: 60)
        expect { guard_service.validate_execution! }.to raise_error(
          Trades::GuardService::ValidationError,
          /only .* available .* locked/
        )
      end

      it 'allows sell when qty within available' do
        trade.update!(qty_requested: 50)
        expect { guard_service.validate_execution! }.not_to raise_error
      end
    end

    context 'when SELL_ALL expansion' do
      let(:trade) do
        # Use amount_requested + NOTIONAL_OK to satisfy validation
        create(:trade, :approved, :sell, agent: agent, ticker: 'AAPL',
               qty_requested: nil, amount_requested: 1000.0, thesis: "SELL_ALL\nNOTIONAL_OK\nSHORT_OK")
      end

      it 'raises ValidationError when no position exists' do
        expect { guard_service.validate_execution! }.to raise_error(
          Trades::GuardService::ValidationError,
          /Cannot SELL_ALL AAPL - no position exists/
        )
      end

      it 'expands qty_requested to position qty' do
        create(:position, agent: agent, ticker: 'AAPL', qty: 150)

        guard_service.validate_execution!
        expect(trade.reload.qty_requested).to eq(150)
      end

      it 'keeps SELL_ALL scoped to this agent when other agents also hold position' do
        create(:position, agent: agent, ticker: 'AAPL', qty: 100)
        other_agent = create(:agent, :logan)
        create(:position, agent: other_agent, ticker: 'AAPL', qty: 50)

        expect { guard_service.validate_execution! }.not_to raise_error
        expect(trade.reload.qty_requested).to eq(100)
      end
    end

    context 'when COVER_ALL expansion' do
      let(:trade) do
        # Use amount_requested to satisfy validation, will be replaced by qty after expansion
        create(:trade, :approved, agent: agent, ticker: 'AAPL', side: 'BUY',
               qty_requested: nil, amount_requested: 1000.0, thesis: 'COVER_ALL')
      end

      it 'raises ValidationError when no short position exists' do
        expect { guard_service.validate_execution! }.to raise_error(
          Trades::GuardService::ValidationError,
          /Cannot COVER_ALL AAPL - no short position exists/
        )
      end

      it 'expands qty_requested to absolute value of short position' do
        create(:position, :short, agent: agent, ticker: 'AAPL', qty: -100)

        guard_service.validate_execution!
        expect(trade.reload.qty_requested).to eq(100)
      end
    end

    context 'when BUY with no special flags' do
      let(:trade) { create(:trade, :approved, agent: agent, ticker: 'AAPL', qty_requested: 100) }

      it 'passes validation without position' do
        expect { guard_service.validate_execution! }.not_to raise_error
      end

      it 'passes validation with existing position' do
        create(:position, agent: agent, ticker: 'AAPL', qty: 50)
        expect { guard_service.validate_execution! }.not_to raise_error
      end
    end

    context 'when BUY exceeds available cash' do
      let(:trade) do
        create(
          :trade,
          :approved,
          agent: agent,
          ticker: 'AAPL',
          side: 'BUY',
          qty_requested: 20,
          limit_price: 200.0
        )
      end

      it 'raises ValidationError for insufficient cash' do
        agent.wallet.update!(cash: 1000.0)
        BrokerAccountSnapshot.create!(broker: 'alpaca', cash: 1000.0, buying_power: 1000.0, equity: 1000.0, fetched_at: Time.current)

        expect { guard_service.validate_execution! }.to raise_error(
          Trades::GuardService::ValidationError,
          /requires \$4000.00 but only \$1000.00/
        )
      end

      it 'passes when cash is sufficient' do
        agent.wallet.update!(cash: 5000.0)
        BrokerAccountSnapshot.create!(broker: 'alpaca', cash: 5000.0, buying_power: 5000.0, equity: 5000.0, fetched_at: Time.current)
        expect { guard_service.validate_execution! }.not_to raise_error
      end
    end

    context 'when BUY uses amount_requested' do
      let(:trade) do
        create(
          :trade,
          :approved,
          :notional,
          agent: agent,
          ticker: 'MSFT',
          side: 'BUY',
          amount_requested: 2500.0
        )
      end

      it 'raises ValidationError if amount exceeds cash' do
        agent.wallet.update!(cash: 1200.0)
        BrokerAccountSnapshot.create!(broker: 'alpaca', cash: 1200.0, buying_power: 1200.0, equity: 1200.0, fetched_at: Time.current)

        expect { guard_service.validate_execution! }.to raise_error(
          Trades::GuardService::ValidationError,
          /requires \$2500.00 but only \$1200.00/
        )
      end
    end
  end
end
