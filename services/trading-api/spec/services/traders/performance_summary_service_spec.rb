# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Traders::PerformanceSummaryService, type: :service do
  include ActiveSupport::Testing::TimeHelpers

  describe '.for' do
    it 'calculates overall and period performance for one trader' do
      travel_to Time.find_zone!("Eastern Time (US & Canada)").parse("2026-04-11 12:00:00") do
        agent = create(:agent, agent_id: 'weston', name: 'Weston', role: 'trader', status: 'active')
        agent.wallet.update!(wallet_size: 25_000.0, cash: 18_000.0, invested: 5_500.0)

        create(:position, agent: agent, ticker: 'AAPL', qty: 10, avg_entry_price: 100.0, current_value: 1_200.0)
        create(:position, agent: agent, ticker: 'MSFT', qty: 20, avg_entry_price: 200.0, current_value: 4_300.0)

        create(:position_lot, :closed, agent: agent, ticker: 'AAPL', closed_at: Time.find_zone!("Eastern Time (US & Canada)").parse("2026-04-08 10:00:00"), realized_pnl: 120.0)
        create(:position_lot, :closed, agent: agent, ticker: 'MSFT', closed_at: Time.find_zone!("Eastern Time (US & Canada)").parse("2026-04-02 10:00:00"), realized_pnl: -20.0)
        create(:position_lot, :closed, agent: agent, ticker: 'KO', closed_at: Time.find_zone!("Eastern Time (US & Canada)").parse("2026-03-28 10:00:00"), realized_pnl: 50.0)

        summary = described_class.for(agent)

        expect(summary).to include(
          wallet_size: 25_000.0,
          cash_now: 18_000.0,
          invested_now: 5_500.0,
          total_value_now: 23_500.0,
          unrealized_pnl_current: 500.0,
          realized_pnl_overall: 150.0,
          realized_pnl_wtd: 120.0,
          realized_pnl_mtd: 100.0,
          total_pnl_overall: 650.0,
          total_return_pct_overall: 2.6,
          utilization_pct: 22.0,
          position_count: 2
        )
      end
    end

    it 'returns zero percentages safely for unfunded agents' do
      agent = create(:agent, agent_id: 'paper', name: 'Paper', role: 'trader', status: 'active')
      agent.wallet.update!(wallet_size: 0.0, cash: 0.0, invested: 0.0)

      summary = described_class.for(agent)

      expect(summary[:total_return_pct_overall]).to eq(0.0)
      expect(summary[:utilization_pct]).to eq(0.0)
      expect(summary[:position_count]).to eq(0)
    end
  end
end
