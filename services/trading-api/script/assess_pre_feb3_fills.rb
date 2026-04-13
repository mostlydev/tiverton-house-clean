#!/usr/bin/env ruby
# frozen_string_literal: true

# Assess feasibility of reconstructing pre-Feb 3 fills from trades table
#
# Usage:
#   bundle exec ruby script/assess_pre_feb3_fills.rb

require_relative '../config/environment'

class PreFeb3Assessment
  START_DATE = '2026-01-26'
  END_DATE = '2026-02-03'

  def run
    print_header
    analyze_trades
    sample_data
    print_recommendation
  end

  private

  def print_header
    puts "Pre-Feb 3 Fills Assessment"
    puts "Date range: #{START_DATE} to #{END_DATE}"
    puts "=" * 80
    puts
  end

  def analyze_trades
    @filled_trades = Trade.where(status: 'FILLED')
                          .where("updated_at BETWEEN ? AND ?", START_DATE, END_DATE)
                          .order(:updated_at)

    @total = @filled_trades.count
    @with_qty = @filled_trades.where.not(qty_filled: nil).count
    @with_price = @filled_trades.where.not(avg_fill_price: nil).count
    @complete = @filled_trades.where.not(qty_filled: nil, avg_fill_price: nil).count

    puts "Filled Trades Analysis"
    puts "-" * 80
    puts "Total FILLED trades:        #{@total}"
    puts "With qty_filled:            #{@with_qty} (#{percentage(@with_qty, @total)}%)"
    puts "With avg_fill_price:        #{@with_price} (#{percentage(@with_price, @total)}%)"
    puts "Complete (both):            #{@complete} (#{percentage(@complete, @total)}%)"
    puts

    if @total > 0
      @data_quality = percentage(@complete, @total)
      puts "Data quality: #{@data_quality}%"
    else
      @data_quality = 0
      puts "Data quality: N/A (no trades found)"
    end
    puts
  end

  def sample_data
    puts "Sample Trades (first 10)"
    puts "-" * 80

    if @filled_trades.any?
      @filled_trades.limit(10).each do |trade|
        status = if trade.qty_filled && trade.avg_fill_price
                   "✓"
                 elsif trade.qty_filled || trade.avg_fill_price
                   "⚠"
                 else
                   "✗"
                 end

        puts "#{status} #{trade.id}: #{trade.ticker} #{trade.side} (#{trade.updated_at.to_date}) - qty: #{trade.qty_filled || 'N/A'}, price: #{trade.avg_fill_price || 'N/A'}"
      end
    else
      puts "(No trades found in date range)"
    end
    puts
  end

  def print_recommendation
    puts "=" * 80
    puts "RECOMMENDATION"
    puts "=" * 80
    puts

    if @total == 0
      puts "No filled trades found in pre-Feb 3 period."
      puts
      puts "✓ ADOPT DAY ZERO APPROACH"
      puts "  - Treat Feb 3, 2026 as inception for realized P&L tracking"
      puts "  - Bootstrap lots already capture cost basis for unrealized P&L"
      puts "  - No historical reconstruction needed"
      puts
    elsif @data_quality >= 80
      puts "Data quality is #{@data_quality}% - reconstruction is feasible."
      puts
      puts "Option 1: RECONSTRUCT PRE-FEB 3 FILLS"
      puts "  - Create fills with fill_id_confidence: 'order_derived'"
      puts "  - Estimated effort: 4-8 hours"
      puts "  - Risk: Medium (reconstructed data may not match broker exactly)"
      puts
      puts "Option 2: DAY ZERO APPROACH (RECOMMENDED)"
      puts "  - Treat Feb 3, 2026 as inception for realized P&L tracking"
      puts "  - Accept historical P&L as unknown (operational loss)"
      puts "  - Focus on forward accuracy from known-good state"
      puts
    else
      puts "Data quality is #{@data_quality}% - reconstruction not recommended."
      puts
      puts "✓ ADOPT DAY ZERO APPROACH"
      puts "  - Data quality too low for reliable reconstruction"
      puts "  - Treat Feb 3, 2026 as inception for realized P&L tracking"
      puts "  - Bootstrap lots already capture cost basis for unrealized P&L"
      puts "  - Historical P&L pre-Feb 3 remains unknown (acceptable)"
      puts
    end

    puts "Rationale for Day Zero:"
    puts "  1. Alpaca has no fill data before Feb 3, 2026"
    puts "  2. Feb 4 bootstrap reconciliation was necessary due to data issues"
    puts "  3. Forward tracking from known-good state is more reliable"
    puts "=" * 80
  end

  def percentage(part, total)
    return 0 if total.zero?
    ((part.to_f / total) * 100).round(1)
  end
end

# Run the assessment
assessment = PreFeb3Assessment.new
assessment.run
