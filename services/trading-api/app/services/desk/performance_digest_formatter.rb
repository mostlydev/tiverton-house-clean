# frozen_string_literal: true

module Desk
  class PerformanceDigestFormatter
    class << self
      def format(summary)
        desk = summary.fetch(:desk)
        traders = summary.fetch(:traders)

        [
          "Desk performance: overall #{signed_compact_dollars(desk[:overall_total_pnl])} | " \
            "WTD realized #{signed_compact_dollars(desk[:wtd_realized_pnl])} | " \
            "MTD realized #{signed_compact_dollars(desk[:mtd_realized_pnl])}",
          traders.map { |trader| "#{display_name(trader)} #{signed_compact_dollars(trader[:total_pnl_overall])}" }.join(" | ")
        ].reject(&:blank?).join("\n")
      end

      private

      def display_name(trader)
        trader[:name].presence || trader[:agent_id]
      end

      def signed_compact_dollars(value)
        sign = value.to_f.negative? ? "-" : "+"
        amount = value.to_f.abs

        formatted_amount =
          if amount >= 1_000_000
            Kernel.format("%.2fM", amount / 1_000_000.0)
          elsif amount >= 1_000
            Kernel.format("%.2fk", amount / 1_000.0)
          else
            Kernel.format("%.0f", amount)
          end

        "#{sign}$#{formatted_amount}"
      end
    end
  end
end
