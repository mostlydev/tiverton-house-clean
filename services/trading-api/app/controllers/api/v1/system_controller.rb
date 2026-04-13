module Api
  module V1
    class SystemController < ApplicationController
      # GET /api/v1/health
      def health
        db = database_healthy?
        rd = redis_healthy?
        broker = broker_healthy?

        overall = db && rd && broker[:authorized]

        render json: {
          status: overall ? 'ok' : 'degraded',
          timestamp: Time.current.iso8601,
          database: db ? 'connected' : 'disconnected',
          redis: rd ? 'connected' : 'disconnected',
          broker: broker
        }
      end

      # GET /api/v1/status
      def status
        broker_account = broker_account_summary
        wallets_summary, positions_summary =
          if LedgerMigration.read_from_ledger?
            ledger_status_summaries(broker_account)
          else
            [legacy_wallet_summary(broker_account), legacy_positions_summary]
          end

        render json: {
          timestamp: Time.current.iso8601,
          ledger_migration: LedgerMigration.status,
          agents: {
            total: Agent.count,
            active: Agent.active.count,
            traders: Agent.traders.count,
            infrastructure: Agent.infrastructure.count
          },
          wallets: wallets_summary,
          broker_account: broker_account,
          trades: {
            total: Trade.count,
            proposed: Trade.proposed.count,
            approved: Trade.approved.count,
            executing: Trade.executing.count,
            filled: Trade.filled.count
          },
          positions: positions_summary
        }
      end

      private

      def database_healthy?
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          conn.exec_query('SELECT 1')
        end
        true
      rescue
        false
      end

      def redis_healthy?
        Redis.new(url: ENV['REDIS_URL']).ping == 'PONG'
      rescue
        false
      end

      def broker_healthy?
        result = Alpaca::BrokerService.new.get_account
        if result[:success]
          {
            authorized: true,
            status: 'active',
            trading_blocked: false
          }
        else
          {
            authorized: false,
            error: result[:error]
          }
        end
      rescue => e
        { authorized: false, error: e.message }
      end

      def legacy_wallet_summary(broker_account)
        total_market_value = Position.sum(:current_value).to_f.round(2)
        total_cash = Wallet.sum(:cash).to_f.round(2)
        total_equity = (total_cash + total_market_value).round(2)

        merge_broker_wallet_context(
          {
            source: "legacy_positions",
            internal_source: "legacy_positions",
            total_capital: Wallet.sum(:wallet_size).to_f,
            total_cash: total_cash,
            total_invested: Wallet.sum(:invested).to_f.round(2),
            total_market_value: total_market_value,
            total_equity: total_equity,
            internal_total_cash: total_cash,
            internal_total_market_value: total_market_value,
            internal_total_equity: total_equity
          },
          broker_account
        )
      end

      def legacy_positions_summary
        {
          source: "legacy_positions",
          total: Position.count,
          open: Position.open_positions.count
        }
      end

      def ledger_status_summaries(broker_account)
        projection = Ledger::ProjectionService.new
        grouped_positions = PositionLot.where(closed_at: nil)
                                       .where("qty > 0")
                                       .group(:agent_id, :ticker)
                                       .select("agent_id, ticker, SUM(qty) AS qty, SUM(total_cost_basis) AS cost_basis")

        prices = latest_price_lookup(grouped_positions.map(&:ticker).uniq)

        total_market_value = 0.0
        total_invested = 0.0

        grouped_positions.each do |row|
          qty = row.qty.to_f
          cost_basis = row.cost_basis.to_f
          price = prices[row.ticker]

          total_market_value += if price.present? && price.positive?
                                  qty * price
                                else
                                  cost_basis
                                end
          total_invested += cost_basis
        end

        total_cash = projection.all_wallets.sum { |wallet| wallet[:cash].to_f }.round(2)
        total_market_value = total_market_value.round(2)
        total_invested = total_invested.round(2)
        total_equity = (total_cash + total_market_value).round(2)

        wallets = merge_broker_wallet_context(
          {
            source: "ledger_lots",
            internal_source: "ledger_lots",
            total_capital: Wallet.sum(:wallet_size).to_f,
            total_cash: total_cash,
            total_invested: total_invested,
            total_market_value: total_market_value,
            total_equity: total_equity,
            internal_total_cash: total_cash,
            internal_total_market_value: total_market_value,
            internal_total_equity: total_equity
          },
          broker_account
        )

        positions = {
          source: "ledger_lots",
          total: grouped_positions.length,
          open: grouped_positions.length
        }

        [wallets, positions]
      end

      def broker_account_summary
        snapshot = BrokerAccountSnapshot.latest
        return { available: false } unless snapshot

        cash = snapshot.cash.to_f.round(2)
        equity = snapshot.equity.to_f.round(2)

        {
          available: true,
          source: "broker_snapshot",
          fetched_at: snapshot.fetched_at,
          cash: cash,
          equity: equity,
          portfolio_value: snapshot.portfolio_value.to_f.round(2),
          buying_power: snapshot.buying_power.to_f.round(2),
          market_value: (equity - cash).round(2),
          fresh: snapshot.fetched_at >= 10.minutes.ago
        }
      end

      def merge_broker_wallet_context(summary, broker_account)
        return summary unless broker_account[:available]

        summary.merge(
          source: "broker_snapshot",
          total_cash: broker_account[:cash],
          total_market_value: broker_account[:market_value],
          total_equity: broker_account[:equity],
          buying_power: broker_account[:buying_power],
          broker_snapshot_fetched_at: broker_account[:fetched_at],
          broker_snapshot_fresh: broker_account[:fresh]
        )
      end

      def latest_price_lookup(tickers)
        return {} if tickers.empty?

        prices = {}
        tickers.each do |ticker|
          price = PriceSample.where(ticker: ticker).order(sampled_at: :desc).limit(1).pick(:price)
          prices[ticker] = price.to_f if price.present?
        end
        prices
      end
    end
  end
end
