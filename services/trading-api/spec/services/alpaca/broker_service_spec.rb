# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Alpaca::BrokerService, type: :service do
  let(:service) { described_class.new }
  let(:mock_client) { double('Alpaca::Trade::Api') } # Use loose double, not instance_double
  let(:mock_order) { double('Order', id: 'order-123', filled_qty: 10, filled_avg_price: 150.0, status: 'filled') }
  let(:mock_quote) { double('Quote', ask_price: 151.0, bid_price: 149.0, last_price: 150.5) }

  before do
    allow_any_instance_of(described_class).to receive(:alpaca_client_class).and_return(Alpaca::Trade::Api)
    allow(Alpaca::Trade::Api).to receive(:new).and_return(mock_client)
  end

  describe '#create_order' do
    context 'with valid market order' do
      it 'creates order successfully with qty' do
        allow(mock_client).to receive(:new_order).and_return(mock_order)

        result = service.create_order(
          ticker: 'AAPL',
          side: 'buy',
          qty: 10,
          order_type: 'market'
        )

        expect(result[:success]).to be true
        expect(result[:order_id]).to eq('order-123')
        expect(result[:qty_filled]).to eq(10)
        expect(result[:avg_fill_price]).to eq(150.0)
        expect(result[:fill_ready]).to be true
      end

      it 'creates order successfully with notional' do
        allow(mock_client).to receive(:new_order).and_return(mock_order)

        result = service.create_order(
          ticker: 'AAPL',
          side: 'buy',
          notional: 1500.0,
          order_type: 'market'
        )

        expect(result[:success]).to be true
        expect(result[:order_id]).to eq('order-123')
      end
    end

    context 'with limit order' do
      it 'includes limit_price in params' do
        expect(mock_client).to receive(:new_order).with(
          hash_including(
            symbol: 'AAPL',
            side: 'buy',
            type: 'limit',
            limit_price: 145.0
          )
        ).and_return(mock_order)

        service.create_order(
          ticker: 'AAPL',
          side: 'buy',
          qty: 10,
          order_type: 'limit',
          limit_price: 145.0
        )
      end
    end

    context 'with validation errors' do
      it 'returns failure when ticker missing' do
        result = service.create_order(
          ticker: '',
          side: 'buy',
          qty: 10,
          order_type: 'market'
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('Ticker is required')
      end

      it 'returns failure when neither qty nor notional provided' do
        result = service.create_order(
          ticker: 'AAPL',
          side: 'buy',
          order_type: 'market'
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('Must specify either qty or notional')
      end

      it 'returns failure when notional used with non-market order' do
        result = service.create_order(
          ticker: 'AAPL',
          side: 'buy',
          notional: 1500.0,
          order_type: 'limit'
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('Notional orders must be market orders')
      end
    end

    context 'when Alpaca API fails' do
      it 'returns failure with error message' do
        allow(mock_client).to receive(:new_order).and_raise(StandardError.new('API error'))

        result = service.create_order(
          ticker: 'AAPL',
          side: 'buy',
          qty: 10,
          order_type: 'market'
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('Order creation failed')
      end
    end
  end

  describe '#close_position' do
    let(:agent) { create(:agent, :westin) }
    let(:mock_close_response) { double('CloseResponse', id: 'order-456', qty: 50, status: 'filled') }

    context 'with single agent holding position' do
      before do
        create(:position, agent: agent, ticker: 'AAPL', qty: 50)
      end

      it 'closes position successfully' do
        allow(mock_client).to receive(:close_position).and_return(mock_close_response)

        result = service.close_position(ticker: 'AAPL', agent_id: agent.agent_id)

        expect(result[:success]).to be true
        expect(result[:order_id]).to eq('order-456')
        expect(result[:qty_closed]).to eq(50)
      end
    end

    context 'with multi-agent position conflict' do
      let(:other_agent) { create(:agent, :logan) }

      before do
        create(:position, agent: agent, ticker: 'AAPL', qty: 50)
        create(:position, agent: other_agent, ticker: 'AAPL', qty: 30)
      end

      it 'returns failure when other agents hold position' do
        result = service.close_position(ticker: 'AAPL', agent_id: agent.agent_id)

        expect(result[:success]).to be false
        expect(result[:error]).to include('Cannot close position via REST API')
        expect(result[:error]).to include('other agents hold')
      end
    end

    context 'without agent_id' do
      it 'skips isolation check' do
        allow(mock_client).to receive(:close_position).and_return(mock_close_response)

        result = service.close_position(ticker: 'AAPL')

        expect(result[:success]).to be true
      end
    end
  end

  describe '#get_quote' do
    it 'returns ask price for BUY' do
      allow_any_instance_of(described_class).to receive(:fetch_latest_quote).and_return({
        bid: 149.0,
        ask: 151.0,
        last: 150.5
      })

      result = service.get_quote(ticker: 'AAPL', side: 'BUY')

      expect(result[:success]).to be true
      expect(result[:price]).to eq(151.0)
    end

    it 'returns bid price for SELL' do
      allow_any_instance_of(described_class).to receive(:fetch_latest_quote).and_return({
        bid: 149.0,
        ask: 151.0,
        last: 150.5
      })

      result = service.get_quote(ticker: 'AAPL', side: 'SELL')

      expect(result[:success]).to be true
      expect(result[:price]).to eq(149.0)
    end

    it 'returns failure when quote fetch fails' do
      allow_any_instance_of(described_class).to receive(:fetch_latest_quote).and_return({
        bid: nil,
        ask: nil,
        last: nil
      })

      result = service.get_quote(ticker: 'AAPL', side: 'BUY')

      expect(result[:success]).to be false
      expect(result[:error]).to include('Quote fetch failed')
    end
  end

  describe '#get_order_status' do
    let(:mock_order_status) do
      double('Order',
        id: 'order-123',
        status: 'filled',
        filled_qty: 10,
        filled_avg_price: 150.0,
        filled_at: Time.current,
        submitted_at: 1.minute.ago,
        updated_at: Time.current
      )
    end

    it 'returns order status successfully' do
      allow(mock_client).to receive(:order).and_return(mock_order_status)

      result = service.get_order_status(order_id: 'order-123')

      expect(result[:success]).to be true
      expect(result[:status]).to eq('filled')
      expect(result[:qty_filled]).to eq(10)
      expect(result[:avg_fill_price]).to eq(150.0)
    end

    it 'returns failure when order not found' do
      allow(mock_client).to receive(:order).and_raise(StandardError.new('Order not found'))

      result = service.get_order_status(order_id: 'invalid-id')

      expect(result[:success]).to be false
      expect(result[:error]).to include('Order status fetch failed')
    end
  end

  describe '#get_positions' do
    let(:mock_positions) do
      [
        double('Position',
          symbol: 'AAPL',
          qty: 10,
          avg_entry_price: 145.0,
          current_price: 150.0,
          market_value: 1500.0,
          cost_basis: 1450.0,
          unrealized_pl: 50.0
        ),
        double('Position',
          symbol: 'GOOGL',
          qty: 5,
          avg_entry_price: 2800.0,
          current_price: 2850.0,
          market_value: 14250.0,
          cost_basis: 14000.0,
          unrealized_pl: 250.0
        )
      ]
    end

    it 'returns all positions' do
      allow(mock_client).to receive(:positions).and_return(mock_positions)

      positions = service.get_positions

      expect(positions.length).to eq(2)
      expect(positions.first[:ticker]).to eq('AAPL')
      expect(positions.first[:qty]).to eq(10)
      expect(positions.last[:ticker]).to eq('GOOGL')
    end

    it 'returns empty array on error' do
      allow(mock_client).to receive(:positions).and_raise(StandardError.new('API error'))

      positions = service.get_positions

      expect(positions).to eq([])
    end
  end

  describe '#get_account' do
    let(:mock_account) do
      double('Account',
        cash: 50000.0,
        portfolio_value: 100000.0,
        buying_power: 75000.0,
        equity: 100000.0
      )
    end

    it 'returns account information' do
      allow(mock_client).to receive(:account).and_return(mock_account)

      result = service.get_account

      expect(result[:success]).to be true
      expect(result[:cash]).to eq(50000.0)
      expect(result[:portfolio_value]).to eq(100000.0)
      expect(result[:equity]).to eq(100000.0)
    end

    it 'returns failure on error' do
      allow(mock_client).to receive(:account).and_raise(StandardError.new('API error'))

      result = service.get_account

      expect(result[:success]).to be false
      expect(result[:error]).to include('Account fetch failed')
    end
  end
end
