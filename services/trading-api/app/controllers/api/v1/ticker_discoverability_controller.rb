# frozen_string_literal: true

module Api
  module V1
    class TickerDiscoverabilityController < ApplicationController
      # GET /api/v1/ticker_discoverability?metric=social_mentions_24h&source=apewisdom&limit=50&only_holdings=false
      def index
        metric = normalize_metric(params[:metric]) || 'social_mentions_24h'
        source = params[:source].presence || 'apewisdom'
        limit = params[:limit].to_i
        limit = 50 if limit <= 0
        only_holdings = ActiveModel::Type::Boolean.new.cast(params[:only_holdings])
        include_stale = ActiveModel::Type::Boolean.new.cast(params[:include_stale])

        cache_key = [
          'ticker_discoverability',
          metric,
          source,
          limit,
          only_holdings,
          include_stale
        ].join(':')

        payload = Rails.cache.fetch(cache_key, expires_in: 2.minutes) do
          build_payload(metric: metric, source: source, limit: limit, only_holdings: only_holdings, include_stale: include_stale)
        end

        render json: payload
      end

      private

      def build_payload(metric:, source:, limit:, only_holdings:, include_stale:)
        records = TickerMetric.latest_by_ticker(metric: metric, source: source)
        records = filter_holdings(records) if only_holdings

        rows = records.map do |record|
          {
            ticker: record.ticker,
            metric: record.metric,
            value: record.value.to_f,
            source: record.source,
            observed_at: record.observed_at.iso8601,
            ttl_seconds: record.ttl_seconds,
            fresh: record.fresh?
          }
        end

        rows.select! { |row| row[:fresh] } unless include_stale
        rows.sort_by! { |row| -row[:value].to_f }

        {
          metric: metric,
          source: source,
          count: rows.size,
          results: rows.first(limit)
        }
      end

      def filter_holdings(records)
        tickers = Position.distinct.pluck(:ticker)
        records.select { |record| tickers.include?(record.ticker) }
      end

      def normalize_metric(value)
        value.to_s.strip.downcase.presence
      end
    end
  end
end
