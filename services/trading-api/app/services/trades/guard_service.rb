# frozen_string_literal: true

module Trades
  class GuardService
    class ValidationError < StandardError; end

    def initialize(trade)
      @trade = trade
      @agent = trade.agent
      @ticker = trade.ticker
      @side = trade.side
    end

    # Validate that trade can be executed
    # Raises ValidationError if checks fail
    def validate_execution!
      check_market_order_params!
      check_notional_order_type!
      check_market_hours_order_type!
      check_short_sell_allowed!
      check_notional_sell_allowed!
      check_sufficient_cash_for_buy! if @side == "BUY"
      if sell_all_requested?
        check_multi_agent_isolation
        expand_sell_all!
      end
      expand_cover_all! if cover_all_requested?
      check_sufficient_position! if @side == "SELL" && @trade.qty_requested
    end

    private

    def check_market_order_params!
      return unless @trade.order_type.to_s.upcase == "MARKET"

      # MARKET orders cannot have limit_price, stop_price, trail_percent, or trail_amount
      invalid_params = []
      invalid_params << "limit_price ($#{@trade.limit_price})" if @trade.limit_price.present?
      invalid_params << "stop_price ($#{@trade.stop_price})" if @trade.stop_price.present?
      invalid_params << "trail_percent (#{@trade.trail_percent}%)" if @trade.trail_percent.present?
      invalid_params << "trail_amount ($#{@trade.trail_amount})" if @trade.trail_amount.present?

      return if invalid_params.empty?

      # Auto-correct: convert MARKET+limit_price to LIMIT order
      if invalid_params.size == 1 && @trade.limit_price.present?
        Rails.logger.info(
          "Auto-correcting #{@trade.trade_id}: MARKET order with limit_price " \
          "converted to LIMIT order at $#{@trade.limit_price}"
        )
        @trade.order_type = "LIMIT"
        @trade.save!
        return
      end

      # Multiple invalid params or stop/trail params - fail with clear error
      raise ValidationError,
            "MARKET orders execute at any price and cannot have #{invalid_params.join(', ')}. " \
            "Use LIMIT order type instead (or remove price constraints for true market execution)."
    end

    def check_notional_order_type!
      return if crypto_like?(@trade.asset_class)
      return if @trade.amount_requested.blank?
      return if @trade.order_type == "MARKET"

      raise ValidationError, "Notional orders must be MARKET. Use qty_requested for #{@trade.order_type} orders."
    end

    def check_short_sell_allowed!
      return unless @side == "SELL"

      position_qty = current_position_qty

      if @trade.asset_class == "crypto"
        if position_qty <= 0
          raise ValidationError, "Cannot short sell crypto. Alpaca does not support crypto short selling."
        end
        return
      end

      # If no position (or negative position), check for SHORT_OK flag
      if position_qty <= 0
        thesis_upper = @trade.thesis.to_s.upcase
        unless thesis_upper.include?("SHORT_OK")
          raise ValidationError, "Cannot SELL #{@ticker} - no position exists for #{@agent.agent_id}. Include SHORT_OK in thesis to allow short selling."
        end
      end
    end

    def check_market_hours_order_type!
      return if crypto_like?(@trade.asset_class)

      session = MarketSessionService.current
      if @trade.asset_class == "us_option"
        if session.regular?
          raise ValidationError, "Options do not support extended_hours." if @trade.extended_hours == true
          return
        end
        raise ValidationError, "Options trade only during regular hours (09:30-16:00 ET)."
      end

      if session.closed?
        raise ValidationError, "Market is closed. Queue the trade for the next valid session."
      end
      return unless session.extended?

      unless @trade.extended_hours == true
        raise ValidationError, "Pre/after-hours orders require extended_hours=true. Set extended_hours or wait for regular hours."
      end

      if @trade.order_type != "LIMIT"
        raise ValidationError, "Pre/after-hours orders must be LIMIT with limit_price. Market/stop/trailing orders are not allowed during extended hours."
      end

      if @trade.limit_price.blank?
        raise ValidationError, "Pre/after-hours LIMIT orders require limit_price."
      end
    end

    def check_notional_sell_allowed!
      return unless @side == "SELL"
      return if crypto_like?(@trade.asset_class)
      return if @trade.qty_requested.present? # OK if qty specified
      return unless @trade.amount_requested.present? # Only check notional sells

      thesis_upper = @trade.thesis.to_s.upcase
      unless thesis_upper.include?("NOTIONAL_OK")
        raise ValidationError, "Notional SELL not allowed for #{@ticker}. Use --qty instead of --amount, or include NOTIONAL_OK in thesis."
      end
    end

    def check_sufficient_position!
      return if sell_all_requested? # Will be validated after expansion
      return unless @trade.qty_requested # Skip if amount-based

      position_qty = current_position_qty

      # Skip check if SHORT_OK flag present (short selling allowed)
      if position_qty <= 0 && @trade.thesis.to_s.upcase.include?("SHORT_OK")
        return
      end

      available_qty = calculate_available_qty(position_qty)
      requested_qty = @trade.qty_requested

      if requested_qty > available_qty
        locked_qty = calculate_locked_qty
        raise ValidationError, "Cannot SELL #{requested_qty} #{@ticker} - only #{available_qty} available (#{locked_qty} locked in pending trades)"
      end
    end

    def check_sufficient_cash_for_buy!
      wallet = @agent.wallet
      raise ValidationError, "Cannot BUY #{@ticker} - wallet not found for #{@agent.agent_id}" unless wallet

      required_cash = estimate_required_buy_cash
      return if required_cash.nil?

      available_cash = available_buying_power
      unless available_cash
        Rails.logger.warn("GuardService: Skipping BUY cash validation for #{@trade.trade_id} - buying power snapshot unavailable")
        return nil
      end

      if required_cash > available_cash
        raise ValidationError,
              "Cannot BUY #{@ticker} - requires $#{format('%.2f', required_cash)} but only " \
              "$#{format('%.2f', available_cash)} buying power is available (account-level)"
      end
    end

    def estimate_required_buy_cash
      if @trade.amount_requested.present?
        return @trade.amount_requested.to_f
      end

      qty = @trade.qty_requested.to_f
      raise ValidationError, "Cannot BUY #{@ticker} - qty or amount is required" if qty <= 0

      reference_price = reference_buy_price
      if reference_price <= 0
        Rails.logger.warn("GuardService: Skipping BUY cash validation for #{@trade.trade_id} - no reference price available")
        return nil
      end

      qty * reference_price
    end

    def reference_buy_price
      # LIMIT/STOP orders have explicit execution bounds; use those before external quote.
      return @trade.limit_price.to_f if @trade.limit_price.present?
      return @trade.stop_price.to_f if @trade.stop_price.present?

      broker = Alpaca::BrokerService.new
      if broker.respond_to?(:get_quote)
        quote = broker.get_quote(ticker: @ticker, side: "BUY", quiet: true, asset_class: @trade.asset_class)
        if quote[:success] && quote[:price].to_f.positive?
          return quote[:price].to_f
        end
      end

      PriceSample.where(ticker: @ticker).order(sampled_at: :desc).limit(1).pick(:price).to_f
    end

    def available_buying_power
      snapshot = BrokerAccountSnapshot.latest
      snapshot = refresh_snapshot_if_stale(snapshot)

      return snapshot.buying_power.to_f if snapshot&.buying_power.to_f.positive?

      nil
    end

    def refresh_snapshot_if_stale(snapshot)
      return snapshot if snapshot&.fetched_at && snapshot.fetched_at >= 2.minutes.ago

      result = BrokerAccountSnapshotService.new.call
      return result[:snapshot] if result[:success]

      snapshot
    rescue StandardError => e
      Rails.logger.warn("GuardService: Snapshot refresh failed: #{e.message}")
      snapshot
    end

    def expand_sell_all!
      position_qty = current_position_qty
      unless position_qty > 0
        raise ValidationError, "Cannot SELL_ALL #{@ticker} - no position exists for #{@agent.agent_id}"
      end

      # In shared tickers, SELL_ALL means "sell this agent's full tracked position".
      # Execution layer handles optional broker-qty snapping when the remaining
      # account position differs by only dust.
      @trade.qty_requested = position_qty
      @trade.save!

      Rails.logger.info("Expanded SELL_ALL for #{@agent.agent_id}/#{@ticker}: qty=#{position_qty}")
    end

    def expand_cover_all!
      position_qty = current_position_qty
      unless position_qty < 0
        raise ValidationError, "Cannot COVER_ALL #{@ticker} - no short position exists for #{@agent.agent_id}"
      end

      # BUY to cover means buying back the absolute value of the short
      @trade.qty_requested = position_qty.abs
      @trade.save!

      Rails.logger.info("Expanded COVER_ALL for #{@agent.agent_id}/#{@ticker}: qty=#{position_qty.abs}")
    end

    def sell_all_requested?
      @trade.thesis.to_s.upcase.include?("SELL_ALL")
    end

    def cover_all_requested?
      @trade.thesis.to_s.upcase.include?("COVER_ALL")
    end

    def calculate_available_qty(position_qty)
      locked_qty = calculate_locked_qty

      [ position_qty - locked_qty, 0 ].max
    end

    def calculate_locked_qty
      # Sum of qty in APPROVED, QUEUED, EXECUTING, PARTIALLY_FILLED SELL trades (excluding current trade)
      Trade.where(
        agent: @agent,
        ticker: @ticker,
        side: "SELL",
        status: [ "APPROVED", "QUEUED", "EXECUTING", "PARTIALLY_FILLED" ]
      ).where.not(id: @trade.id)
       .sum(:qty_requested) || 0
    end

    def crypto_like?(asset_class)
      %w[crypto crypto_perp].include?(asset_class)
    end

    def check_multi_agent_isolation
      other_agent_ids = other_holder_agent_ids

      if other_agent_ids.any?
        agent_names = Agent.where(id: other_agent_ids).pluck(:agent_id).join(", ")
        # Log warning but allow SELL_ALL to proceed: expand_sell_all! scopes qty to
        # this agent's tracked position, and the execution layer decides whether to
        # use REST position close or a standard qty-based order.
        Rails.logger.info(
          "SELL_ALL #{@ticker} by #{@agent.agent_id}: other agents also hold position " \
          "(#{agent_names}). Expanding to agent-scoped qty; execution layer will use " \
          "standard order instead of REST position close."
        )
      end
    end

    def current_position_qty
      if LedgerMigration.read_from_ledger?
        projection = Ledger::ProjectionService.new
        position = projection.position_for(@agent, @ticker)
        position ? position[:qty].to_f : 0
      else
        Position.find_by(agent: @agent, ticker: @ticker)&.qty.to_f || 0
      end
    end

    def other_holder_agent_ids
      if LedgerMigration.read_from_ledger?
        PositionLot.where(ticker: @ticker.to_s.upcase, closed_at: nil)
                   .where.not(agent_id: @agent.id)
                   .group(:agent_id)
                   .having("SUM(qty) != 0")
                   .pluck(:agent_id)
      else
        Position.where(ticker: @ticker)
                .where.not(agent_id: @agent.id)
                .where("qty != 0")
                .pluck(:agent_id)
      end
    end
  end
end
