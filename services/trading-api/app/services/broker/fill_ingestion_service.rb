# frozen_string_literal: true

require "securerandom"

module Broker
  # Handles the complete fill ingestion workflow:
  # 1. Creates BrokerFill record (idempotent)
  # 2. Updates BrokerOrder status
  # 3. Posts to ledger (double-entry)
  # 4. Updates position lots
  # 5. Publishes outbox event
  #
  # Single-writer rule: Only this service may write broker_fills, ledger_entries,
  # and position_lots. Called from AccountActivitiesIngestionJob and
  # (post-migration) from OrderReconciliationService.
  class FillIngestionService
    include ActiveModel::Model

    Result = Struct.new(:success, :fill, :errors, keyword_init: true)

    attr_reader :errors

    def initialize
      @errors = []
    end

    # Ingest a fill from Activities API or order status
    # Returns Result with :success, :fill, :errors
    def ingest!(
      broker_fill_id: nil,
      broker_order_id: nil,
      trade: nil,
      agent: nil,
      ticker:,
      side:,
      qty:,
      price:,
      executed_at:,
      fill_id_confidence: nil,
      raw_fill: {}
    )
      # Normalize side to match ledger expectations
      normalized_side = normalize_fill_side(side)

      # Determine confidence level
      confidence = fill_id_confidence || (broker_fill_id.present? ? 'broker_verified' : 'order_derived')

      # Check for existing fill (idempotency)
      existing_fill = find_existing_fill(broker_fill_id, broker_order_id, executed_at, qty)
      if existing_fill
        if broker_fill_id.present? && !existing_fill.fill_id_confidence_broker_verified?
          upgrade_fill_confidence!(existing_fill, new_broker_fill_id: broker_fill_id)
        end
        Rails.logger.info("[FillIngestion] Skipping duplicate fill: #{broker_fill_id || 'composite'}")
        return Result.new(success: true, fill: existing_fill, errors: [])
      end

      # If an order-derived fill already exists for this order, upgrade it to broker_verified
      if broker_fill_id.present? && broker_order_id.present?
        upgraded = try_upgrade_order_derived_fill(
          broker_order_id: broker_order_id,
          broker_fill_id: broker_fill_id,
          qty: qty,
          price: price,
          executed_at: executed_at
        )
        return Result.new(success: true, fill: upgraded, errors: []) if upgraded
      end

      # Resolve broker_order if we have broker_order_id
      broker_order = resolve_broker_order(broker_order_id, trade: trade, raw_fill: raw_fill)

      # Ensure we have a trade to link fills to (create external trade if needed)
        trade = resolve_trade(
          trade,
          broker_order,
          raw_fill: raw_fill,
          ticker: ticker,
          side: normalized_side,
          qty: qty,
          price: price,
          executed_at: executed_at
        )

      # Resolve agent from various sources
      resolved_agent = agent || trade&.agent || broker_order&.agent || system_agent

      # If broker-verified arrives after order-derived full fill, split the derived fill to avoid double-counting.
      if broker_fill_id.present? && broker_order
        split_result = split_order_derived_for_verified!(
          broker_order: broker_order,
          trade: trade,
          agent: resolved_agent,
          ticker: ticker,
          side: side,
          incoming_qty: qty,
          incoming_price: price,
          incoming_executed_at: executed_at,
          incoming_broker_fill_id: broker_fill_id
        )

        if split_result == :skip_verified
          Rails.logger.warn("[FillIngestion] Skipping broker-verified fill: unable to safely split order-derived remainder.")
          return Result.new(success: true, fill: nil, errors: [])
        end
      end

      if broker_order && resolved_agent && broker_order.agent_id.nil?
        broker_order.update!(agent: resolved_agent)
      end

      if broker_order && trade && broker_order.trade_id.nil?
        broker_order.update!(trade: trade)
      end

      fill = nil
      ActiveRecord::Base.transaction do
        # 1. Create BrokerFill record
        fill = BrokerFill.create!(
          broker_fill_id: broker_fill_id,
          broker_order: broker_order,
          trade: trade,
          agent: resolved_agent,
          ticker: TickerNormalizer.normalize(ticker),
          side: normalized_side,
          qty: qty,
          price: price,
          value: qty * price,
          executed_at: executed_at,
          fill_id_confidence: confidence,
          raw_fill: raw_fill
        )

        # 2. Update broker order status if linked
        update_broker_order_status(broker_order, fill) if broker_order

        # 3. Post to ledger (unless migration mode is active and ledger posting is disabled)
        unless skip_ledger_posting?
          post_to_ledger(fill, resolved_agent)
        end

        # 4. Update position lots
        unless skip_lot_updates?
          update_position_lots(fill, resolved_agent)
        end

        # 5. Publish outbox event for notifications
        publish_fill_event(fill, trade)
      end

      enqueue_snapshot_refresh
      Result.new(success: true, fill: fill, errors: [])

    rescue ActiveRecord::RecordNotUnique => e
      Rails.logger.warn("[FillIngestion] Duplicate fill detected: #{e.message}")
      Result.new(success: true, fill: find_existing_fill(broker_fill_id, broker_order_id, executed_at, qty), errors: [])

    rescue StandardError => e
      Rails.logger.error("[FillIngestion] Failed to ingest fill: #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))
      Result.new(success: false, fill: nil, errors: [e.message])
    end

    # Ingest a fill from order status delta (when Activities API fill ID unavailable)
    # Uses cumulative qty to derive individual fills
    def ingest_from_order_status!(
      broker_order_id:,
      trade:,
      current_qty_filled:,
      current_avg_price:,
      filled_at: nil
    )
      broker_order = BrokerOrder.find_by(broker_order_id: broker_order_id)
      return Result.new(success: false, fill: nil, errors: ['Broker order not found']) unless broker_order

      # If broker-verified fills already cover this order, skip order-derived ingestion
      verified_qty = BrokerFill.where(broker_order: broker_order, fill_id_confidence: 'broker_verified').sum(:qty)
      if verified_qty.to_f >= current_qty_filled.to_f - 0.000001
        Rails.logger.info("[FillIngestion] Skipping order-derived fill: broker-verified qty covers order (#{verified_qty} >= #{current_qty_filled})")
        return Result.new(success: true, fill: nil, errors: [])
      end

      # Calculate delta from previous fills
      previous_qty = broker_order.broker_fills.sum(:qty)
      delta_qty = current_qty_filled - previous_qty

      return Result.new(success: true, fill: nil, errors: []) if delta_qty <= 0

      # Ingest the delta as a new fill
      ingest!(
        broker_order_id: broker_order_id,
        trade: trade,
        agent: trade&.agent || broker_order&.agent,
        ticker: broker_order.ticker,
        side: broker_order.side,
        qty: delta_qty,
        price: current_avg_price, # Note: may be interpolated if avg across multiple fills
        executed_at: filled_at || Time.current,
        fill_id_confidence: 'order_derived',
        raw_fill: {
          source: 'order_status_delta',
          cumulative_qty: current_qty_filled,
          previous_qty: previous_qty,
          delta_qty: delta_qty
        }
      )
    end

    # Upgrade fill confidence when better data becomes available
    def upgrade_fill_confidence!(fill, new_broker_fill_id:)
      return if fill.broker_fill_id.present? && fill.fill_id_confidence_broker_verified?

      fill.update!(
        broker_fill_id: new_broker_fill_id,
        fill_id_confidence: 'broker_verified'
      )

      Rails.logger.info("[FillIngestion] Upgraded fill #{fill.id} confidence to broker_verified")
    end

    private

    def find_existing_fill(broker_fill_id, broker_order_id, executed_at, qty)
      # First try by broker_fill_id
      if broker_fill_id.present?
        fill = BrokerFill.find_by(broker_fill_id: broker_fill_id)
        return fill if fill
      end

      # Fall back to composite key
      if broker_order_id.present?
        broker_order = BrokerOrder.find_by(broker_order_id: broker_order_id)
        if broker_order
          BrokerFill.find_by(
            broker_order_id: broker_order.id,
            executed_at: executed_at,
            qty: qty
          )
        end
      end
    end

    def normalize_fill_side(side)
      s = side.to_s.downcase
      return 'sell' if s == 'sell_short' || s == 'short'
      return 'buy' if s == 'buy_to_cover' || s == 'cover'

      s
    end

    def try_upgrade_order_derived_fill(broker_order_id:, broker_fill_id:, qty:, price:, executed_at:)
      return nil if executed_at.nil?

      broker_order = BrokerOrder.find_by(broker_order_id: broker_order_id)
      return nil unless broker_order

      qty = qty.to_f
      price = price.to_f

      qty_tol = 0.0001
      price_tol = 0.01
      time_window = 5.minutes

      candidate = BrokerFill.where(broker_order: broker_order, fill_id_confidence: 'order_derived')
                            .where('qty BETWEEN ? AND ?', qty - qty_tol, qty + qty_tol)
                            .where('price BETWEEN ? AND ?', price - price_tol, price + price_tol)
                            .where('executed_at BETWEEN ? AND ?', executed_at - time_window, executed_at + time_window)
                            .order(executed_at: :asc)
                            .first

      return nil unless candidate

      upgrade_fill_confidence!(candidate, new_broker_fill_id: broker_fill_id)
      candidate
    end

    def split_order_derived_for_verified!(broker_order:, trade:, agent:, ticker:, side:, incoming_qty:, incoming_price:, incoming_executed_at:, incoming_broker_fill_id:)
      derived_fills = BrokerFill.where(broker_order: broker_order, fill_id_confidence: 'order_derived').to_a
      return :noop if derived_fills.empty?

      derived_qty = derived_fills.sum { |f| f.qty.to_f }
      return :noop if derived_qty <= 0

      order_qty = broker_order.qty_requested.to_f
      order_qty = trade&.qty_requested.to_f if order_qty <= 0
      order_qty = derived_qty if order_qty <= 0

      verified_qty = BrokerFill.where(broker_order: broker_order, fill_id_confidence: 'broker_verified').sum(:qty).to_f
      projected_total = verified_qty + incoming_qty.to_f + derived_qty

      excess = projected_total - order_qty
      return :noop if excess <= 0.000001

      remainder_qty = derived_qty - excess
      remainder_qty = 0 if remainder_qty < 0

      template = derived_fills.max_by { |f| f.executed_at || Time.at(0) }
      template_price = template&.price.to_f
      template_price = incoming_price.to_f if template_price <= 0

      template_time = template&.executed_at || incoming_executed_at || Time.current

      ActiveRecord::Base.transaction do
        derived_fills.each { |fill| rollback_fill_effects!(fill) }

        if remainder_qty > 0.000001
          ingest!(
            broker_fill_id: nil,
            broker_order_id: broker_order.broker_order_id,
            trade: trade,
            agent: agent,
            ticker: template&.ticker || ticker,
            side: template&.side || side,
            qty: remainder_qty,
            price: template_price,
            executed_at: template_time,
            fill_id_confidence: 'order_derived',
            raw_fill: {
              source: 'order_status_remainder',
              original_derived_qty: derived_qty,
              remainder_qty: remainder_qty,
              replaced_by_broker_fill_id: incoming_broker_fill_id
            }
          )
        end
      end

      :adjusted
    rescue StandardError => e
      Rails.logger.error("[FillIngestion] Failed to split order-derived fill: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))

      # If derived already covers the order, skip the verified fill to avoid double-counting.
      derived_qty >= order_qty - 0.000001 ? :skip_verified : :noop
    end

    def rollback_fill_effects!(fill)
      # Remove ledger postings for the fill itself.
      tx_ids = LedgerTransaction.where(source_type: 'BrokerFill', source_id: fill.id).pluck(:id)
      LedgerEntry.where(ledger_transaction_id: tx_ids).delete_all
      LedgerTransaction.where(id: tx_ids).delete_all

      closed_lots = PositionLot.where(close_source_type: 'BrokerFill', close_source_id: fill.id).to_a
      if closed_lots.any?
        pnl_tx_ids = LedgerTransaction.where(source_type: 'PositionLot', source_id: closed_lots.map(&:id)).pluck(:id)
        LedgerEntry.where(ledger_transaction_id: pnl_tx_ids).delete_all
        LedgerTransaction.where(id: pnl_tx_ids).delete_all
      end

      if fill.side == 'buy'
        open_lots = PositionLot.where(open_source_type: 'BrokerFill', open_source_id: fill.id).to_a
        if open_lots.any? { |lot| lot.close_source_id.present? }
          raise "Cannot rollback BUY fill #{fill.id}: lots already closed by other fills"
        end
        open_lots.each(&:destroy!)
      else
        closed_lots.each do |lot|
          open_lot = PositionLot.where(
            open_source_type: lot.open_source_type,
            open_source_id: lot.open_source_id,
            closed_at: nil
          ).first

          if open_lot
            new_qty = open_lot.qty + lot.qty
            open_lot.update!(qty: new_qty, total_cost_basis: open_lot.cost_basis_per_share * new_qty)
            lot.destroy!
          else
            lot.update!(closed_at: nil, close_source_type: nil, close_source_id: nil, realized_pnl: nil)
          end
        end
      end

      fill.destroy!
    end

    def enqueue_snapshot_refresh
      return unless BrokerAccountSnapshot.stale?(max_age_seconds: 60)

      BrokerAccountSnapshotJob.perform_later
    rescue StandardError => e
      Rails.logger.warn("[FillIngestion] Snapshot refresh enqueue failed: #{e.message}")
    end

    def resolve_broker_order(broker_order_id, trade: nil, raw_fill: {})
      return nil if broker_order_id.blank?

      broker_order = BrokerOrder.find_by(broker_order_id: broker_order_id)
      return broker_order if broker_order

      if trade
        return BrokerOrder.create!(
          broker_order_id: broker_order_id,
          client_order_id: trade.trade_id || SecureRandom.uuid,
          trade: trade,
          agent: trade.agent,
          ticker: trade.ticker,
          side: trade.side.to_s.downcase,
          order_type: trade.order_type.to_s.downcase.presence || "market",
          time_in_force: raw_fill[:time_in_force],
          requested_tif: raw_fill[:time_in_force],
          effective_tif: raw_fill[:time_in_force],
          extended_hours: trade.extended_hours,
          qty_requested: trade.qty_requested,
          notional_requested: trade.amount_requested,
          limit_price: trade.limit_price,
          stop_price: trade.stop_price,
          trail_percent: trade.trail_percent,
          trail_price: trade.trail_amount,
          status: raw_fill[:status],
          submitted_at: raw_fill[:transaction_time],
          raw_request: { source: "fill_ingestion", trade_id: trade.trade_id },
          raw_response: raw_fill,
          asset_class: trade.asset_class
        )
      end

      # If no trade linked, create a stub broker order so fills can reference it.
      # This avoids orphaned broker_fills when activities arrive before order sync.
      create_stub_broker_order(broker_order_id, raw_fill)
    rescue ActiveRecord::RecordNotUnique
      BrokerOrder.find_by(broker_order_id: broker_order_id)
    end

    def create_stub_broker_order(broker_order_id, raw_fill)
      data = raw_fill.is_a?(Hash) ? raw_fill : {}
      symbol = data[:symbol] || data["symbol"] || data[:ticker] || data["ticker"] || "UNKNOWN"
      side = data[:side] || data["side"] || "buy"
      status = data[:status] || data["status"] || "filled"
      submitted_at = data[:transaction_time] || data["transaction_time"]
      order_type = data[:order_type] || data["order_type"] || "market"

      client_order_id = data[:client_order_id] || data["client_order_id"] || "external-#{broker_order_id}"
      agent = infer_agent_from_client_order_id(client_order_id) || infer_agent_from_raw_fill(data)
      agent ||= system_agent

      trade = Trade.find_by(alpaca_order_id: broker_order_id) ||
              Trade.find_by(trade_id: "external-#{broker_order_id}")

      unless trade
        qty = data[:qty] || data["qty"] || data[:quantity] || data["quantity"] || data[:filled_qty] || data["filled_qty"]
        price = data[:price] || data["price"] || data[:fill_price] || data["fill_price"]
        executed_at = data[:transaction_time] || data["transaction_time"] || Time.current

        qty = qty.to_f if qty
        price = price.to_f if price

        trade = Trade.create!(
          trade_id: "external-#{broker_order_id}",
          agent: agent,
          ticker: TickerNormalizer.normalize(symbol),
          side: side.to_s.upcase,
          qty_requested: qty || 0,
          amount_requested: data[:notional] || data["notional"],
          order_type: normalize_order_type(order_type),
          status: map_order_status_to_trade_status(status),
          thesis: "EXTERNAL_FILL",
          approved_by: "system",
          approved_at: submitted_at || executed_at,
          confirmed_at: submitted_at || executed_at,
          executed_by: "system",
          execution_started_at: submitted_at || executed_at,
          execution_completed_at: executed_at,
          alpaca_order_id: broker_order_id,
          qty_filled: qty,
          avg_fill_price: price,
          filled_value: qty && price ? qty * price : nil,
          extended_hours: false,
          asset_class: infer_asset_class_from_ticker(symbol),
          execution_policy: agent&.default_execution_policy || "allow_extended",
          is_urgent: false
        )
      end

      BrokerOrder.create!(
        broker_order_id: broker_order_id,
        client_order_id: client_order_id,
        trade: trade,
        agent: agent,
        ticker: TickerNormalizer.normalize(symbol),
        side: side.to_s.downcase,
        order_type: order_type.to_s.downcase,
        status: status,
        submitted_at: submitted_at,
        raw_request: { source: "fill_ingestion_stub" },
        raw_response: data,
        asset_class: infer_asset_class_from_ticker(symbol)
      )
    rescue ActiveRecord::RecordNotUnique
      BrokerOrder.find_by(broker_order_id: broker_order_id)
    end

    def resolve_trade(trade, broker_order, raw_fill:, ticker:, side:, qty:, price:, executed_at:)
      return trade if trade
      return broker_order.trade if broker_order&.trade
      return nil unless broker_order

      agent = broker_order.agent || infer_agent_from_client_order_id(broker_order.client_order_id) || infer_agent_from_raw_fill(raw_fill)
      agent ||= system_agent

      if broker_order.agent_id.nil? && agent
        broker_order.update!(agent: agent)
      end

      existing = Trade.find_by(alpaca_order_id: broker_order.broker_order_id) ||
                 Trade.find_by(trade_id: "external-#{broker_order.broker_order_id}")
      return existing if existing

      qty_requested = broker_order.qty_requested || qty
      amount_requested = broker_order.notional_requested
      avg_fill_price = price.to_f
      filled_value = qty_requested.to_f.positive? ? (qty_requested.to_f * avg_fill_price) : nil

      status = map_order_status_to_trade_status(broker_order.status)

      trade = Trade.create!(
        trade_id: "external-#{broker_order.broker_order_id}",
        agent: agent || system_agent,
        ticker: TickerNormalizer.normalize(broker_order.ticker || ticker),
        side: (broker_order.side || side).to_s.upcase,
        qty_requested: qty_requested,
        amount_requested: amount_requested,
        order_type: normalize_order_type(broker_order.order_type),
        status: status,
        thesis: "EXTERNAL_FILL",
        approved_by: "system",
        approved_at: broker_order.submitted_at || executed_at,
        confirmed_at: broker_order.submitted_at || executed_at,
        executed_by: "system",
        execution_started_at: broker_order.submitted_at || executed_at,
        execution_completed_at: broker_order.filled_at || executed_at,
        alpaca_order_id: broker_order.broker_order_id,
        qty_filled: qty_requested,
        avg_fill_price: avg_fill_price,
        filled_value: filled_value,
        extended_hours: broker_order.extended_hours || false,
        asset_class: broker_order.asset_class || infer_asset_class_from_ticker(broker_order.ticker || ticker),
        execution_policy: agent&.default_execution_policy || "allow_extended",
        is_urgent: false
      )

      broker_order.update!(trade: trade) if broker_order.trade_id.nil?
      trade
    end

    def infer_agent_from_client_order_id(client_order_id)
      return nil if client_order_id.blank?

      match = client_order_id.to_s.match(/\A([a-z]+)-/)
      return nil unless match

      Agent.find_by(agent_id: match[1])
    end

    def infer_agent_from_raw_fill(raw_fill)
      data = raw_fill.is_a?(Hash) ? raw_fill : {}
      client_order_id = data[:client_order_id] || data["client_order_id"] || data[:order_client_id] || data["order_client_id"]
      infer_agent_from_client_order_id(client_order_id)
    end

    def normalize_order_type(order_type)
      ot = order_type.to_s.upcase
      return "MARKET" if ot.empty?
      return ot if %w[MARKET LIMIT STOP STOP_LIMIT TRAILING_STOP].include?(ot)

      "MARKET"
    end

    def map_order_status_to_trade_status(status)
      case status.to_s.downcase
      when "filled"
        "FILLED"
      when "partially_filled"
        "EXECUTING"
      when "canceled", "cancelled"
        "CANCELLED"
      when "rejected", "expired", "failed"
        "FAILED"
      else
        "EXECUTING"
      end
    end

    def system_agent
      @system_agent ||= Agent.find_by(agent_id: "system")
    end

    def infer_asset_class_from_ticker(ticker)
      t = ticker.to_s
      return "crypto" if t.include?("/")
      return "us_option" if t.match?(/\A[A-Z]{1,6}\d{6}[CP]\d{8}\z/)
      "us_equity"
    end

    def update_broker_order_status(broker_order, fill)
      total_filled = broker_order.broker_fills.sum(:qty)
      requested = broker_order.qty_requested || 0

      new_status = if total_filled >= requested
                     'filled'
                   elsif total_filled > 0
                     'partially_filled'
                   else
                     broker_order.status
                   end

      if new_status != broker_order.status
        broker_order.update!(status: new_status, filled_at: fill.executed_at)

        # Create order event
        BrokerOrderEvent.create!(
          broker_order: broker_order,
          event_type: new_status == 'filled' ? 'filled' : 'partial_fill',
          broker_event_ts: fill.executed_at,
          qty_filled: fill.qty,
          avg_fill_price: fill.price,
          cumulative_qty: total_filled
        )
      end
    end

    def post_to_ledger(fill, agent)
      return unless agent

      posting = Ledger::PostingService.new(
        source_type: 'BrokerFill',
        source_id: fill.id,
        agent: agent.agent_id,
        asset: fill.ticker,
        booked_at: fill.executed_at,
        description: "#{fill.side.upcase} #{fill.qty} #{fill.ticker} @ #{fill.price}"
      )

      # Double-entry posting for fill
      # BUY: Debit position asset, Credit cash
      # SELL: Debit cash, Credit position asset
      cash_account = "agent:#{agent.agent_id}:cash"
      position_account = "agent:#{agent.agent_id}:#{fill.ticker}"

      if fill.side == 'buy'
        posting.add_entry(account_code: position_account, amount: fill.value, asset: fill.ticker)
        posting.add_entry(account_code: cash_account, amount: -fill.value, asset: 'USD')
      else # sell
        posting.add_entry(account_code: cash_account, amount: fill.value, asset: 'USD')
        posting.add_entry(account_code: position_account, amount: -fill.value, asset: fill.ticker)
      end

      posting.post!
    end

    def update_position_lots(fill, agent)
      return unless agent

      if fill.side == 'buy'
        # Open new lot(s)
        PositionLot.create!(
          agent: agent,
          ticker: fill.ticker,
          qty: fill.qty,
          cost_basis_per_share: fill.price,
          total_cost_basis: fill.value,
          opened_at: fill.executed_at,
          open_source_type: 'BrokerFill',
          open_source_id: fill.id
        )
      else # sell
        # Close existing lots (FIFO)
        close_lots_fifo(agent, fill)
      end
    end

    def close_lots_fifo(agent, fill)
      remaining_qty = fill.qty
      open_lots = PositionLot
                  .where(agent: agent, ticker: fill.ticker, closed_at: nil)
                  .where('qty > 0')
                  .order(:opened_at)

      open_lots.each do |lot|
        break if remaining_qty <= 0

        qty_to_close = [lot.qty, remaining_qty].min
        realized_pnl = (fill.price - lot.cost_basis_per_share) * qty_to_close

        closed_lot = nil
        if qty_to_close >= lot.qty
          # Close entire lot
          lot.update!(
            closed_at: fill.executed_at,
            close_source_type: 'BrokerFill',
            close_source_id: fill.id,
            realized_pnl: realized_pnl
          )
          closed_lot = lot
        else
          # Split lot: reduce current lot, create remainder
          new_qty = lot.qty - qty_to_close
          lot.update!(qty: new_qty, total_cost_basis: lot.cost_basis_per_share * new_qty)

          # Create closed portion as new lot
          closed_lot = PositionLot.create!(
            agent: agent,
            ticker: lot.ticker,
            qty: qty_to_close,
            cost_basis_per_share: lot.cost_basis_per_share,
            total_cost_basis: lot.cost_basis_per_share * qty_to_close,
            opened_at: lot.opened_at,
            closed_at: fill.executed_at,
            open_source_type: lot.open_source_type,
            open_source_id: lot.open_source_id,
            close_source_type: 'BrokerFill',
            close_source_id: fill.id,
            realized_pnl: realized_pnl
          )
        end

        # Post realized P&L to ledger
        unless skip_ledger_posting?
          post_realized_pnl_to_ledger(agent, fill, closed_lot, realized_pnl)
        end

        remaining_qty -= qty_to_close
      end

      if remaining_qty > 0
        Rails.logger.warn("[FillIngestion] Oversold: #{remaining_qty} shares of #{fill.ticker} for agent #{agent.agent_id}")
        # This could indicate a short position - create negative lot
        PositionLot.create!(
          agent: agent,
          ticker: fill.ticker,
          qty: -remaining_qty,
          cost_basis_per_share: fill.price,
          total_cost_basis: -remaining_qty * fill.price,
          opened_at: fill.executed_at,
          open_source_type: 'BrokerFill',
          open_source_id: fill.id
        )
      end
    end

    def publish_fill_event(fill, trade)
      return unless trade
      # Notifications are handled by Trade AASM callbacks; avoid duplicate fill messages.
    end

    def skip_ledger_posting?
      # During Phase 2 shadow mode, we may want to skip ledger posting
      # until we're confident in the data
      ENV['LEDGER_SKIP_POSTING'] == 'true'
    end

    def skip_lot_updates?
      # During Phase 2 shadow mode, we may want to skip lot updates
      ENV['LEDGER_SKIP_LOT_UPDATES'] == 'true'
    end

    def skip_pnl_posting?
      ENV['LEDGER_SKIP_PNL_POSTING'] == 'true'
    end

    def post_realized_pnl_to_ledger(agent, fill, closed_lot, realized_pnl)
      return if realized_pnl.zero?
      return if skip_pnl_posting?

      posting = Ledger::PostingService.new(
        source_type: 'PositionLot',
        source_id: closed_lot.id,
        agent: agent.agent_id,
        asset: 'USD',
        booked_at: fill.executed_at,
        description: "Realized #{realized_pnl >= 0 ? 'gain' : 'loss'}: #{closed_lot.ticker}"
      )

      # Account codes
      pnl_account = "agent:#{agent.agent_id}:realized_pnl"
      cost_adjustment = "agent:#{agent.agent_id}:cost_basis_adjustment"

      # Double-entry: P&L and cost basis adjustment
      posting.add_entry(account_code: pnl_account, amount: realized_pnl, asset: 'USD')
      posting.add_entry(account_code: cost_adjustment, amount: -realized_pnl, asset: 'USD')

      posting.post!
    rescue StandardError => e
      Rails.logger.error("[FillIngestion] P&L posting failed: #{e.message}")
      # Don't fail entire fill ingestion on P&L posting error
    end
  end
end
