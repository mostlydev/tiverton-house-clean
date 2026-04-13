# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Desk::PerformanceSummaryService, type: :service do
  include ActiveSupport::Testing::TimeHelpers

  describe '.call' do
    it 'returns funded active traders sorted by total pnl and aggregated desk totals' do
      travel_to Time.find_zone!("Eastern Time (US & Canada)").parse("2026-04-11 12:00:00") do
        weston = create(:agent, agent_id: 'weston', name: 'Weston', role: 'trader', status: 'active')
        weston.wallet.update!(wallet_size: 25_000.0, cash: 10_000.0, invested: 1_300.0)
        create(:position, agent: weston, ticker: 'NVDA', qty: 10, avg_entry_price: 100.0, current_value: 1_300.0)
        create(:position_lot, :closed, agent: weston, ticker: 'NVDA', closed_at: Time.find_zone!("Eastern Time (US & Canada)").parse("2026-04-08 09:45:00"), realized_pnl: 100.0)

        logan = create(:agent, agent_id: 'logan', name: 'Logan', role: 'trader', status: 'active')
        logan.wallet.update!(wallet_size: 25_000.0, cash: 15_000.0, invested: 900.0)
        create(:position, agent: logan, ticker: 'JNJ', qty: 10, avg_entry_price: 100.0, current_value: 900.0)
        create(:position_lot, :closed, agent: logan, ticker: 'JNJ', closed_at: Time.find_zone!("Eastern Time (US & Canada)").parse("2026-04-07 11:30:00"), realized_pnl: -50.0)

        unfunded = create(:agent, agent_id: 'bench', name: 'Bench', role: 'trader', status: 'active')
        unfunded.wallet.update!(wallet_size: 0.0, cash: 0.0, invested: 0.0)

        summary = described_class.call

        expect(summary[:traders].map { |row| row[:agent_id] }).to eq(%w[weston logan])
        expect(summary[:desk]).to include(
          overall_total_pnl: 250.0,
          overall_realized_pnl: 50.0,
          overall_unrealized_pnl: 200.0,
          wtd_realized_pnl: 50.0,
          mtd_realized_pnl: 50.0,
          funded_trader_count: 2
        )
        expect(summary[:period_starts][:wtd]).to start_with("2026-04-06")
        expect(summary[:period_starts][:mtd]).to start_with("2026-04-01")
      end
    end
  end
end
