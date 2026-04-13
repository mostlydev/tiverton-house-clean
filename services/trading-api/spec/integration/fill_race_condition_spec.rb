require 'rails_helper'

RSpec.describe "Fill Race Condition", type: :service do
  let(:agent) { create(:agent, :westin) }
  let(:trade) { create(:trade, :executing, agent: agent, ticker: 'AAPL', qty_requested: 100) }
  let(:wallet) { agent.wallet }

  before do
    # Initial state
    wallet.update!(cash: 20000.0, invested: 0)
  end

  it "prevents position doubling when two services process the same fill data" do
    # Simulate first process (e.g. TradeExecutionService)
    processor1 = Trades::FillProcessorService.new(trade)
    
    # Simulate second process starting concurrently (e.g. OrderReconciliationJob)
    processor2 = Trades::FillProcessorService.new(trade)

    # Process 1 completes
    processor1.process_fill(
      qty_filled: 100,
      avg_fill_price: 150.0,
      final: true
    )

    trade.reload
    position = Position.find_by(agent: agent, ticker: 'AAPL')
    expect(position.qty).to eq(100)
    expect(wallet.reload.cash).to eq(5000.0) # 20000 - (100 * 150)

    # Process 2 attempts the same fill data
    # Before the fix, this would have added ANOTHER 100 shares
    processor2.process_fill(
      qty_filled: 100,
      avg_fill_price: 150.0,
      final: true
    )

    trade.reload
    position.reload
    expect(position.qty).to eq(100) # Should NOT be 200
    expect(wallet.reload.cash).to eq(5000.0) # Should NOT be -10000
  end

  it "handles incremental fills correctly without double-counting the initial part" do
    processor = Trades::FillProcessorService.new(trade)

    # Partial fill 1: 50 shares
    processor.process_fill(qty_filled: 50, avg_fill_price: 150.0, final: false)
    
    expect(Position.find_by(agent: agent, ticker: 'AAPL').qty).to eq(50)

    # Concurrent reconciliation sees same 50 shares
    processor_concurrent = Trades::FillProcessorService.new(trade)
    processor_concurrent.process_fill(qty_filled: 50, avg_fill_price: 150.0, final: false)

    expect(Position.find_by(agent: agent, ticker: 'AAPL').qty).to eq(50) # Still 50

    # New fill data: 100 shares total
    processor.process_fill(qty_filled: 100, avg_fill_price: 150.0, final: true)
    
    expect(Position.find_by(agent: agent, ticker: 'AAPL').qty).to eq(100)
  end
end
