# frozen_string_literal: true

module Desk
  class PerformanceSummaryService
    class << self
      def call
        trader_rows = funded_traders.map do |agent|
          {
            agent_id: agent.agent_id,
            name: agent.name
          }.merge(Traders::PerformanceSummaryService.for(agent))
        end.sort_by { |row| [ -row[:total_pnl_overall], row[:agent_id] ] }

        {
          as_of: Time.current.iso8601,
          period_starts: {
            wtd: Traders::PerformanceSummaryService.week_start_et.iso8601,
            mtd: Traders::PerformanceSummaryService.month_start_et.iso8601
          },
          desk: {
            overall_total_pnl: sum_rows(trader_rows, :total_pnl_overall),
            overall_realized_pnl: sum_rows(trader_rows, :realized_pnl_overall),
            overall_unrealized_pnl: sum_rows(trader_rows, :unrealized_pnl_current),
            wtd_realized_pnl: sum_rows(trader_rows, :realized_pnl_wtd),
            mtd_realized_pnl: sum_rows(trader_rows, :realized_pnl_mtd),
            funded_trader_count: trader_rows.size
          },
          traders: trader_rows
        }
      end

      private

      def funded_traders
        Agent.active.traders.includes(:wallet).select do |agent|
          agent.wallet&.wallet_size.to_f.positive?
        end
      end

      def sum_rows(rows, key)
        rows.sum { |row| row[key].to_f }.round(2)
      end
    end
  end
end
