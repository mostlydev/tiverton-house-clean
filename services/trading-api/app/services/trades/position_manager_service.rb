# frozen_string_literal: true

module Trades
  class PositionManagerService
    DUST_THRESHOLD = 0.01

    # Error raised when mutations are blocked by ledger migration guard
    class WriteGuardError < StandardError; end

    def initialize(trade)
      @trade = trade
      @agent = trade.agent
      @ticker = trade.ticker
      @side = trade.side
    end

    # Apply delta from fill to positions and wallet
    # Uses atomic transaction to ensure consistency
    #
    # LEDGER MIGRATION:
    # - write_guard_enabled: Block all writes (Phase 0-2)
    # - ledger_only_writes: Block legacy writes (Phase 5)
    # - write_to_legacy: Allow legacy writes (legacy or dual mode)
    def apply_delta(delta)
      # GUARD: Legacy writes blocked in ledger_only mode (Phase 5+)
      if LedgerMigration.block_legacy_write?('PositionManagerService#apply_delta')
        log_blocked_delta(delta)
        return # Skip legacy mutation
      end

      ActiveRecord::Base.transaction do
        if @side == 'BUY'
          apply_buy_delta(
            delta_qty: delta[:delta_qty],
            delta_price: delta[:delta_price],
            delta_value: delta[:delta_value]
          )
        else
          apply_sell_delta(
            delta_qty: delta[:delta_qty],
            delta_value: delta[:delta_value]
          )
        end
      end
    rescue StandardError => e
      Rails.logger.error("Position update failed for #{@trade.trade_id}: #{e.message}")
      raise
    end

    def log_blocked_delta(delta)
      Rails.logger.info(
        "[LEDGER_MIGRATION] Blocked legacy position/wallet mutation for #{@trade.trade_id}: " \
        "#{@side} #{@ticker} delta_qty=#{delta[:delta_qty]} delta_value=#{delta[:delta_value]} " \
        "(write_mode=#{LedgerMigration.write_mode})"
      )
    end

    private

    # Apply BUY delta: increase position with VWAP calculation
    def apply_buy_delta(delta_qty:, delta_price:, delta_value:)
      position = Position.find_or_initialize_by(agent: @agent, ticker: @ticker)
      effective_stop_loss = resolve_stop_loss(position, delta_qty, delta_value)

      if position.new_record?
        # New position
        position.qty = delta_qty
        position.asset_class = @trade.asset_class
        position.avg_entry_price = delta_value / delta_qty if delta_qty > 0
        position.current_value = delta_value
        position.opened_at = Time.current
      else
        # Add to existing position with weighted average (VWAP)
        old_qty = position.qty || 0
        old_price = position.avg_entry_price || 0

        total_cost = (old_qty * old_price) + delta_value
        total_qty = old_qty + delta_qty

        position.qty = total_qty
        position.avg_entry_price = total_qty > 0 ? (total_cost / total_qty) : old_price
        position.current_value = total_qty * position.avg_entry_price
      end

      apply_stop_loss!(position, effective_stop_loss)

      position.save!

      # Update wallet: decrease cash, increase invested
      wallet = @agent.wallet
      wallet.cash -= delta_value
      wallet.invested += delta_value
      wallet.save!

      Rails.logger.info("BUY applied: #{@agent.agent_id}/#{@ticker} +#{delta_qty}@#{position.avg_entry_price} (cash: #{wallet.cash})")
    end

    # Apply SELL delta: reduce position using cost basis from avg_entry_price
    def apply_sell_delta(delta_qty:, delta_value:)
      position = Position.find_by!(agent: @agent, ticker: @ticker)

      # Use avg_entry_price as cost basis (not fill price)
      cost_basis_price = position.avg_entry_price || 0
      cost_basis_value = delta_qty * cost_basis_price

      # Reduce position
      new_qty = position.qty - delta_qty

      if new_qty.abs < DUST_THRESHOLD
        # Position closed - delete dust
        Rails.logger.info("SELL closed position: #{@agent.agent_id}/#{@ticker} (dust: #{new_qty})")
        position.destroy!
      else
        position.qty = new_qty
        position.current_value = new_qty * position.avg_entry_price
        position.save!
        Rails.logger.info("SELL applied: #{@agent.agent_id}/#{@ticker} -#{delta_qty}@#{@trade.avg_fill_price} (remaining: #{new_qty})")
      end

      # Update wallet: increase cash by proceeds, decrease invested by cost basis
      wallet = @agent.wallet
      wallet.cash += delta_value
      wallet.invested -= cost_basis_value
      wallet.save!

      # Calculate realized P&L
      realized_pl = delta_value - cost_basis_value
      Rails.logger.info("Realized P&L: #{realized_pl} (proceeds: #{delta_value}, cost: #{cost_basis_value})")
    end

    def resolve_stop_loss(position, delta_qty, delta_value)
      trade_stop_loss = @trade.stop_loss.to_f
      return trade_stop_loss if trade_stop_loss.positive?

      existing_stop = position.stop_loss.to_f
      return existing_stop if existing_stop.positive?

      entry = if position.persisted? && position.avg_entry_price.to_f.positive?
                position.avg_entry_price.to_f
      elsif delta_qty.to_f.positive?
                delta_value.to_f / delta_qty.to_f
      else
                0
      end

      fallback = entry * (1.0 - AppConfig.stop_loss_fallback_percent)
      raise ArgumentError, "Cannot derive stop_loss for #{@agent.agent_id}/#{@ticker}" unless fallback.positive?

      fallback.round(4)
    end

    def apply_stop_loss!(position, effective_stop_loss)
      previous_stop_loss = position.stop_loss.to_f
      position.stop_loss = effective_stop_loss
      position.stop_loss_source_trade_id = @trade.id if @trade.stop_loss.to_f.positive?

      return if previous_stop_loss.positive? && (previous_stop_loss - effective_stop_loss.to_f).abs < 0.0001

      position.stop_loss_triggered_at = nil
      position.stop_loss_last_alert_at = nil
      position.stop_loss_alert_count = 0
    end
  end
end
