# frozen_string_literal: true

module Trades
  class OrderReconciliationService
    # Poll-only mode: fetch statuses and log, but don't mutate trades/positions/wallets
    # Set LEDGER_MIGRATION_WRITE_GUARD=true to enable
    def call
      trades = Trade.where(status: ['EXECUTING', 'PARTIALLY_FILLED'])
                    .where.not(alpaca_order_id: nil)

      mode = LedgerMigration.write_guard_enabled? ? 'POLL-ONLY' : 'NORMAL'
      Rails.logger.info("Reconciling #{trades.count} executing trades [mode=#{mode}]")

      trades.each do |trade|
        reconcile_trade(trade)
      end
    end

    private

    def reconcile_trade(trade)
      broker = Alpaca::BrokerService.new
      result = broker.get_order_status(order_id: trade.alpaca_order_id)

      unless result[:success]
        Rails.logger.warn("Could not fetch status for order #{trade.alpaca_order_id}: #{result[:error]}")
        return
      end

      update_from_status(trade, result)
    rescue StandardError => e
      Rails.logger.error("Reconciliation failed for #{trade.trade_id}: #{e.message}")
    end

    def update_from_status(trade, status)
      case status[:status]
      when 'filled'
        handle_filled(trade, status)

      when 'partially_filled'
        handle_partial_fill(trade, status)

      when 'canceled', 'expired', 'rejected'
        handle_failed(trade, status)

      when 'pending_new', 'new', 'accepted'
        Rails.logger.debug("Order #{trade.alpaca_order_id} still pending")

      else
        Rails.logger.warn("Unknown order status for #{trade.alpaca_order_id}: #{status[:status]}")
      end
    end

    def handle_filled(trade, status)
      return unless trade.qty_filled != status[:qty_filled] || trade.avg_fill_price != status[:avg_fill_price]

      Rails.logger.info("Fill detected for #{trade.trade_id}: #{status[:qty_filled]}@#{status[:avg_fill_price]}")

      if LedgerMigration.write_guard_enabled?
        LedgerMigration.log_blocked_mutation(
          'OrderReconciliationService#handle_filled',
          trade_id: trade.trade_id,
          ticker: trade.ticker,
          qty_filled: status[:qty_filled],
          avg_fill_price: status[:avg_fill_price],
          action: 'process_fill(final: true)'
        )
        return
      end

      fill_processor = Trades::FillProcessorService.new(trade)
      fill_processor.process_fill(
        qty_filled: status[:qty_filled],
        avg_fill_price: status[:avg_fill_price],
        final: true
      )

    end

    def handle_partial_fill(trade, status)
      return unless trade.qty_filled != status[:qty_filled] || trade.avg_fill_price != status[:avg_fill_price]

      Rails.logger.info("Partial fill detected for #{trade.trade_id}: #{status[:qty_filled]}@#{status[:avg_fill_price]}")

      if LedgerMigration.write_guard_enabled?
        LedgerMigration.log_blocked_mutation(
          'OrderReconciliationService#handle_partial_fill',
          trade_id: trade.trade_id,
          ticker: trade.ticker,
          qty_filled: status[:qty_filled],
          avg_fill_price: status[:avg_fill_price],
          action: 'process_fill(final: false)'
        )
        return
      end

      fill_processor = Trades::FillProcessorService.new(trade)
      fill_processor.process_fill(
        qty_filled: status[:qty_filled],
        avg_fill_price: status[:avg_fill_price],
        final: false
      )

    end

    def handle_failed(trade, status)
      Rails.logger.warn("Order #{trade.alpaca_order_id} status: #{status[:status]}")

      if LedgerMigration.write_guard_enabled?
        LedgerMigration.log_blocked_mutation(
          'OrderReconciliationService#handle_failed',
          trade_id: trade.trade_id,
          ticker: trade.ticker,
          status: status[:status],
          action: 'trade.fail!'
        )
        return
      end

      trade.execution_error = "Order #{status[:status]}"
      trade.fail!

    end
  end
end
