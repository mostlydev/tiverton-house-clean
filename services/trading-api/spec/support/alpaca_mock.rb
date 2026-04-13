# frozen_string_literal: true

# Helper module for mocking Alpaca::BrokerService in tests
#
# Usage in specs:
#   let(:broker) { alpaca_mock_broker }
#   before { alpaca_mock_fill(broker, ticker: 'AAPL', side: 'buy', qty: 10, price: 150.0) }
#
module AlpacaMock
  # Create a mock broker and stub Alpaca::BrokerService.new
  def alpaca_mock_broker
    broker = instance_double(Alpaca::BrokerService)
    allow(Alpaca::BrokerService).to receive(:new).and_return(broker)
    broker
  end

  # Mock a successful market order fill
  def alpaca_mock_fill(broker, ticker:, side:, qty:, price:)
    allow(broker).to receive(:create_order).with(
      hash_including(ticker: ticker, side: side.downcase)
    ).and_return({
      success: true,
      order_id: "alpaca-#{SecureRandom.hex(4)}",
      qty_filled: qty,
      avg_fill_price: price,
      filled_value: qty * price,
      fill_ready: true
    })
  end

  # Mock a pending order (no fill yet)
  def alpaca_mock_pending(broker, ticker:)
    allow(broker).to receive(:create_order).with(
      hash_including(ticker: ticker)
    ).and_return({
      success: true,
      order_id: "alpaca-#{SecureRandom.hex(4)}",
      qty_filled: 0,
      avg_fill_price: 0,
      filled_value: 0,
      fill_ready: false,
      status: 'pending_new'
    })
  end

  # Mock order creation failure
  def alpaca_mock_failure(broker, error:)
    allow(broker).to receive(:create_order).and_return({
      success: false,
      error: error
    })
  end

  # Mock position close (SELL_ALL)
  def alpaca_mock_close(broker, ticker:, qty:, price:)
    allow(broker).to receive(:close_position).with(
      hash_including(ticker: ticker)
    ).and_return({
      success: true,
      order_id: "alpaca-close-#{SecureRandom.hex(4)}",
      qty_closed: qty,
      status: 'filled'
    })

    allow(broker).to receive(:get_quote).with(
      hash_including(ticker: ticker)
    ).and_return({
      success: true,
      price: price
    })
  end

  # Mock get_positions for reconciliation
  def alpaca_mock_positions(broker, positions)
    formatted = positions.map do |p|
      {
        ticker: p[:ticker],
        qty: p[:qty],
        avg_entry_price: p[:avg_entry_price],
        market_value: p[:qty] * (p[:current_price] || p[:avg_entry_price]),
        current_price: p[:current_price] || p[:avg_entry_price]
      }
    end
    allow(broker).to receive(:get_positions).and_return(formatted)
  end

  # Mock get_account
  def alpaca_mock_account(broker, cash:, equity:)
    allow(broker).to receive(:get_account).and_return({
      cash: cash,
      equity: equity,
      buying_power: cash * 2,
      long_market_value: equity - cash
    })
  end

  # Mock quote for price lookups
  def alpaca_mock_quote(broker, ticker:, price:)
    allow(broker).to receive(:get_quote).with(
      hash_including(ticker: ticker)
    ).and_return({
      success: true,
      price: price,
      bid: price - 0.01,
      ask: price + 0.01
    })
  end
end

RSpec.configure do |config|
  config.include AlpacaMock
end
