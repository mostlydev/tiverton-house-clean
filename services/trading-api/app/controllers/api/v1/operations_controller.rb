# frozen_string_literal: true

module Api
  module V1
    class OperationsController < ApplicationController
      before_action :require_coordinator_or_internal_api_principal!

      # POST /api/v1/operations/news_poll
      def news_poll
        NewsPollJob.perform_now
        render json: { ok: true, run_at: Time.current.iso8601 }
      rescue StandardError => e
        render json: { ok: false, error: e.message }, status: :service_unavailable
      end

      # POST /api/v1/operations/alpaca_consistency
      def alpaca_consistency
        result = Alpaca::ConsistencyService.new(
          positions: !truthy?(params[:cash_only]),
          cash: !truthy?(params[:positions_only]),
          qty_tolerance: params[:qty_tolerance] || 0.0001,
          cash_tolerance: params[:cash_tolerance] || 5.0
        ).call

        render json: result, status: result[:ok] ? :ok : :unprocessable_entity
      rescue StandardError => e
        render json: { ok: false, error: e.message }, status: :service_unavailable
      end

      # POST /api/v1/operations/alpaca_align
      def alpaca_align
        result = Alpaca::AlignmentService.new(
          apply: truthy?(params[:apply]),
          positions: !falsey?(params[:positions]),
          cash: !falsey?(params[:cash]),
          qty_tolerance: params[:qty_tolerance] || 0.0001,
          cash_tolerance: params[:cash_tolerance] || 5.0
        ).call

        render json: result, status: result[:ok] ? :ok : :unprocessable_entity
      rescue StandardError => e
        render json: { ok: false, error: e.message }, status: :service_unavailable
      end

      # POST /api/v1/operations/wallet_funding_sync
      def wallet_funding_sync
        snapshot = latest_or_refreshed_snapshot
        return render json: snapshot, status: :unprocessable_entity unless snapshot[:success]

        result = Wallets::BrokerFundingSyncService.new(
          snapshot: snapshot[:snapshot],
          force: truthy?(params[:force])
        ).call

        status =
          if result[:success]
            :ok
          else
            :unprocessable_entity
          end

        render json: result, status: status
      rescue StandardError => e
        render json: { success: false, error: e.message }, status: :service_unavailable
      end

      # POST /api/v1/operations/market_data_backfill
      def market_data_backfill
        days = params[:days].to_i
        days = MarketDataBackfillService::DEFAULT_DAYS if days <= 0
        tickers = normalize_tickers(params[:tickers])

        job = MarketDataBackfillJob.perform_later(days: days, tickers: tickers)
        render json: {
          queued: true,
          job_id: job.job_id,
          days: days,
          tickers: tickers.presence || 'tracked_equities_plus_benchmarks'
        }, status: :accepted
      rescue StandardError => e
        render json: { queued: false, error: e.message }, status: :service_unavailable
      end

      # POST /api/v1/operations/dividend_snapshot_refresh
      def dividend_snapshot_refresh
        tickers = normalize_tickers(params[:tickers])

        job = DividendSnapshotRefreshJob.perform_later(tickers: tickers.presence)
        render json: {
          queued: true,
          job_id: job.job_id,
          tickers: tickers.presence || 'tracked_equities'
        }, status: :accepted
      rescue StandardError => e
        render json: { queued: false, error: e.message }, status: :service_unavailable
      end

      # POST /api/v1/operations/trader_context_prime
      def trader_context_prime
        days = params[:days].to_i
        days = MarketDataBackfillService::DEFAULT_DAYS if days <= 0
        tickers = normalize_tickers(params[:tickers])

        job = TraderContextPrimeJob.perform_later(days: days, tickers: tickers.presence)
        render json: {
          queued: true,
          job_id: job.job_id,
          days: days,
          tickers: tickers.presence || 'tracked_equities_plus_benchmarks'
        }, status: :accepted
      rescue StandardError => e
        render json: { queued: false, error: e.message }, status: :service_unavailable
      end

      private

      def truthy?(value)
        ActiveModel::Type::Boolean.new.cast(value)
      end

      def falsey?(value)
        return false if value.nil?

        !truthy?(value)
      end

      def latest_or_refreshed_snapshot
        if truthy?(params[:refresh_snapshot])
          result = BrokerAccountSnapshotService.new.call
          return result if result[:success]

          return { success: false, error: result[:error] || "snapshot refresh failed" }
        end

        snapshot = BrokerAccountSnapshot.latest
        return { success: false, error: "no broker account snapshot found" } unless snapshot

        { success: true, snapshot: snapshot }
      end

      def normalize_tickers(value)
        return [] if value.blank?

        value.to_s.split(',').map { |ticker| TickerNormalizer.normalize(ticker) }.reject(&:blank?).uniq
      end
    end
  end
end
