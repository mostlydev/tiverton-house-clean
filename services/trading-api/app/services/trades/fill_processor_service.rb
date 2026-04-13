# frozen_string_literal: true

module Trades
  class FillProcessorService
    DUST_THRESHOLD = 0.000001

    attr_reader :trade, :delta_qty, :delta_price, :delta_value, :filled_value

    def initialize(trade)
      @trade = trade
      @delta_qty = 0
      @delta_price = 0
      @delta_value = 0
      @filled_value = 0
    end

    # Process a fill (full or partial)
    # Returns: { delta_qty:, delta_price:, delta_value:, filled_value:, status: }
    def process_fill(qty_filled:, avg_fill_price:, alpaca_order_id: nil, final: true)
      @trade.with_lock do
        # Clean tiny floating point dust
        qty_filled = clean_dust_qty(qty_filled)
        avg_fill_price = avg_fill_price.to_f

        # Calculate deltas (incremental, not overwrite)
        old_qty = @trade.qty_filled || 0
        old_avg_price = @trade.avg_fill_price || 0

        @delta_qty = qty_filled - old_qty

        # IDEMPOTENCY GUARD: If delta_qty is zero and avg_price hasn't changed, skip processing
        # This prevents duplicate updates if reconciliation and execution overlap.
        if @delta_qty.abs < DUST_THRESHOLD && (avg_fill_price - old_avg_price).abs < DUST_THRESHOLD
          Rails.logger.info("FillProcessor: No change detected for #{@trade.trade_id}, skipping.")
          return { delta_qty: 0, delta_price: 0, delta_value: 0, filled_value: @trade.filled_value, status: @trade.status, avg_fill_price: @trade.avg_fill_price }
        end

        # If no fill price provided, get fallback from quote
        if avg_fill_price.zero?
          avg_fill_price = get_fallback_price
        end

        # ABORT if we still have no price (prevents validation errors in PositionManager)
        if avg_fill_price.zero?
          Rails.logger.warn("FillProcessor: Price is 0 for #{@trade.trade_id}, skipping.")
          return { delta_qty: 0, delta_price: 0, delta_value: 0, filled_value: @trade.filled_value, status: @trade.status, avg_fill_price: @trade.avg_fill_price }
        end

        # Calculate new VWAP from cumulative values
        old_total_value = old_qty * old_avg_price
        new_total_value = qty_filled * avg_fill_price
        @delta_value = new_total_value - old_total_value
        new_avg_price = qty_filled > 0 ? new_total_value / qty_filled : 0

        @delta_price = new_avg_price - old_avg_price
        @filled_value = new_total_value

        # Update trade record
        @trade.qty_filled = qty_filled
        @trade.avg_fill_price = new_avg_price
        @trade.filled_value = @filled_value
        @trade.alpaca_order_id = alpaca_order_id if alpaca_order_id

        # Determine status
        if final || fill_complete?
          if @trade.may_fill?
            @trade.fill!
          elsif @trade.may_complete_fill?
            @trade.complete_fill!
          end
        elsif @delta_qty > 0
          # Partial fill
          @trade.partial_fill! if @trade.may_partial_fill?
        end

        @trade.save!

        # Log to audit trail
        log_fill_event(final: final)

        # Apply delta to positions and wallet within the same lock
        sync_fill_state if @delta_qty.abs >= DUST_THRESHOLD
      end

      {
        delta_qty: @delta_qty,
        delta_price: @delta_price,
        delta_value: @delta_value,
        filled_value: @filled_value,
        status: @trade.status,
        avg_fill_price: @trade.avg_fill_price
      }
    rescue StandardError => e
      Rails.logger.error("Fill processing failed for #{@trade.trade_id}: #{e.message}")
      raise
    end

    private

    def sync_fill_state
      ingest_fill_artifacts if should_ingest_fill_artifacts?
      apply_legacy_delta unless LedgerMigration.block_legacy_write?("FillProcessorService#process_fill")
    end

    def should_ingest_fill_artifacts?
      return true unless LedgerMigration.write_guard_enabled?

      LedgerMigration.log_blocked_mutation(
        "FillProcessorService#ingest_fill_artifacts",
        trade_id: @trade.trade_id,
        ticker: @trade.ticker,
        delta_qty: @delta_qty,
        delta_value: @delta_value,
        action: "ingest_fill_artifacts"
      )
      false
    end

    def apply_legacy_delta
      position_manager = Trades::PositionManagerService.new(@trade)
      position_manager.apply_delta({
        delta_qty: @delta_qty,
        delta_price: @delta_price,
        delta_value: @delta_value,
        filled_value: @filled_value
      })
    end

    def ingest_fill_artifacts
      ingestion = Broker::FillIngestionService.new
      result = ingestion.ingest!(
        broker_order_id: @trade.alpaca_order_id,
        trade: @trade,
        agent: @trade.agent,
        ticker: @trade.ticker,
        side: @trade.side,
        qty: @delta_qty,
        price: @trade.avg_fill_price,
        executed_at: Time.current,
        fill_id_confidence: "order_derived",
        raw_fill: {
          source: "fill_processor",
          trade_id: @trade.trade_id,
          delta_qty: @delta_qty,
          delta_value: @delta_value
        }
      )

      unless result.success
        Rails.logger.error("[FillProcessor] Fill ingestion failed: #{result.errors.join(', ')}")
      end
    end

    def clean_dust_qty(qty)
      return 0 if qty.nil?
      qty = qty.to_f
      qty.abs < DUST_THRESHOLD ? 0 : qty
    end

    def get_fallback_price
      # Get quote price as fallback when fill price unavailable
      broker = Alpaca::BrokerService.new
      result = broker.get_quote(ticker: @trade.ticker, side: @trade.side)

      if result[:success]
        result[:price]
      else
        Rails.logger.warn("Could not get fallback price for #{@trade.ticker}, using 0")
        0
      end
    end

    def fill_complete?
      # Check if qty_filled >= qty_requested (accounting for floating point)
      return false unless @trade.qty_requested && @trade.qty_filled

      qty_filled = @trade.qty_filled.to_f
      qty_requested = @trade.qty_requested.to_f

      (qty_filled - qty_requested).abs < DUST_THRESHOLD || qty_filled >= qty_requested
    end

    def log_fill_event(final:)
      event_type = final ? "FILLED" : "PARTIALLY_FILLED"
      details = {
        qty_filled: @trade.qty_filled,
        avg_fill_price: @trade.avg_fill_price,
        filled_value: @filled_value,
        delta_qty: @delta_qty,
        delta_value: @delta_value
      }

      TradeEvent.create!(
        trade: @trade,
        event_type: event_type,
        actor: @trade.executed_by || "system",
        details: details.to_json
      )
    end
  end
end
