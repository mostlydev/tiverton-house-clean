# frozen_string_literal: true

module Traders
  class PerformanceSummaryService
    TIMEZONE_NAME = "Eastern Time (US & Canada)"

    class << self
      def for(agent)
        wallet = agent.wallet || Wallet.find_by(agent: agent)
        positions = Position.where(agent: agent)
        closed_lots = PositionLot.where(agent: agent).closed

        wallet_size = wallet&.wallet_size.to_f
        cash_now = wallet&.cash.to_f
        invested_now = positions.sum(:current_value).to_f
        unrealized_pnl_current = positions.sum("current_value - qty * avg_entry_price").to_f
        realized_pnl_overall = closed_lots.sum(:realized_pnl).to_f
        realized_pnl_wtd = closed_lots.where("closed_at >= ?", week_start_et).sum(:realized_pnl).to_f
        realized_pnl_mtd = closed_lots.where("closed_at >= ?", month_start_et).sum(:realized_pnl).to_f
        total_pnl_overall = realized_pnl_overall + unrealized_pnl_current

        {
          wallet_size: round_money(wallet_size),
          cash_now: round_money(cash_now),
          invested_now: round_money(invested_now),
          total_value_now: round_money(cash_now + invested_now),
          utilization_pct: round_percentage(invested_now, wallet_size),
          unrealized_pnl_current: round_money(unrealized_pnl_current),
          realized_pnl_overall: round_money(realized_pnl_overall),
          realized_pnl_wtd: round_money(realized_pnl_wtd),
          realized_pnl_mtd: round_money(realized_pnl_mtd),
          total_pnl_overall: round_money(total_pnl_overall),
          total_return_pct_overall: round_percentage(total_pnl_overall, wallet_size),
          position_count: positions.where("ABS(qty) >= 1").count
        }
      end

      def week_start_et(reference_time = Time.current)
        eastern_time(reference_time).beginning_of_week(:monday).beginning_of_day
      end

      def month_start_et(reference_time = Time.current)
        eastern_time(reference_time).beginning_of_month.beginning_of_day
      end

      private

      def eastern_time(reference_time)
        reference_time.in_time_zone(TIMEZONE_NAME)
      end

      def round_money(value)
        value.round(2)
      end

      def round_percentage(numerator, denominator)
        return 0.0 unless denominator.to_f.positive?

        ((numerator.to_f / denominator.to_f) * 100).round(2)
      end
    end
  end
end
