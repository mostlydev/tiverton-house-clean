# frozen_string_literal: true

module Api
  module V1
    class TickerMetricsController < ApplicationController
      before_action :require_internal_api_principal!, only: :bulk

      # GET /api/v1/ticker_metrics?ticker=XYZ&metrics=foo,bar&sources=alpha,beta&include_stale=true
      # Optional: period_type=quarterly|annual|ttm, history=true&limit=8, refresh=true
      def index
        ticker = normalize_ticker(params[:ticker])
        return render json: { error: 'ticker is required' }, status: :unprocessable_entity if ticker.blank?

        metrics = normalize_list(params[:metrics])
        sources = normalize_list(params[:sources], downcase: false)
        period_type = normalize_period_type(params[:period_type])
        include_stale = ActiveModel::Type::Boolean.new.cast(params[:include_stale])
        history = ActiveModel::Type::Boolean.new.cast(params[:history])
        refresh = ActiveModel::Type::Boolean.new.cast(params[:refresh])
        limit = params[:limit].to_i
        limit = 8 if limit <= 0

        records = if history
          TickerMetric.history_for(ticker: ticker, metrics: metrics, sources: sources, period_type: period_type, limit: limit)
        else
          TickerMetric.latest_for(ticker: ticker, metrics: metrics, sources: sources, period_type: period_type)
        end
        now = Time.current

        payload = records.map { |record| metric_json(record, now: now) }
        payload.select! { |entry| entry[:fresh] } unless include_stale

        refresh_info = enqueue_refresh_if_needed(
          ticker: ticker,
          metrics: metrics,
          payload: payload,
          refresh: refresh,
          period_type: period_type,
          history: history,
          limit: limit
        )

        render json: { ticker: ticker, metrics: payload, refresh: refresh_info }
      end

      # POST /api/v1/ticker_metrics/bulk
      def bulk
        payload = params[:metrics] || params[:_json]
        return render json: { error: 'metrics payload is required' }, status: :unprocessable_entity if payload.blank?
        return render json: { error: 'metrics payload must be an array' }, status: :unprocessable_entity unless payload.is_a?(Array)

        now = Time.current
        rows = []
        errors = []

        payload.each_with_index do |entry, index|
          entry = entry.to_unsafe_h if entry.respond_to?(:to_unsafe_h)
          unless entry.is_a?(Hash)
            errors << { index: index, error: 'each metric must be an object' }
            next
          end

          ticker = normalize_ticker(entry[:ticker] || entry['ticker'])
          metric = normalize_metric(entry[:metric] || entry['metric'])
          value = parse_numeric(entry[:value] || entry['value'])
          source = (entry[:source] || entry['source'] || params[:source] || 'unknown').to_s.strip
          observed_at = parse_timestamp(entry[:observed_at] || entry['observed_at'] || entry[:ts] || entry['ts'])
          period_type = normalize_period_type(entry[:period_type] || entry['period_type'])
          period_start = parse_date(entry[:period_start] || entry['period_start'])
          period_end = parse_date(entry[:period_end] || entry['period_end'])
          fiscal_year = parse_integer(entry[:fiscal_year] || entry['fiscal_year'], allow_nil: true)
          fiscal_quarter = parse_integer(entry[:fiscal_quarter] || entry['fiscal_quarter'], allow_nil: true)
          is_derived = ActiveModel::Type::Boolean.new.cast(entry[:is_derived] || entry['is_derived'])
          is_derived = false if is_derived.nil?
          confidence = parse_numeric(entry[:confidence] || entry['confidence'], allow_nil: true)
          meta = entry[:meta] || entry['meta']
          meta = meta.is_a?(Hash) ? meta : nil

          if ticker.blank? || metric.blank? || value.nil?
            errors << { index: index, error: 'ticker, metric, and value are required' }
            next
          end

          if observed_at.nil?
            errors << { index: index, error: 'observed_at/ts is invalid' }
            next
          end

          rows << {
            ticker: ticker,
            metric: metric,
            value: value,
            period_type: period_type,
            period_start: period_start,
            period_end: period_end,
            fiscal_year: fiscal_year,
            fiscal_quarter: fiscal_quarter,
            is_derived: is_derived,
            source: source.presence || 'unknown',
            observed_at: observed_at,
            confidence: confidence,
            meta: meta,
            created_at: now,
            updated_at: now
          }
        end

        if errors.any?
          return render json: { error: 'invalid metrics payload', details: errors }, status: :unprocessable_entity
        end

        TickerMetric.insert_all!(rows)
        render json: { inserted: rows.size }
      end

      private

      def metric_json(record, now: Time.current)
        {
          ticker: record.ticker,
          metric: record.metric,
          label: AppConfig.ticker_metrics_label(record.metric),
          hint: AppConfig.ticker_metrics_hint(record.metric),
          format: AppConfig.ticker_metrics_format(record.metric),
          value: record.value.to_f,
          source: record.source,
          observed_at: record.observed_at.iso8601,
          period_type: record.period_type,
          period_start: record.period_start&.iso8601,
          period_end: record.period_end&.iso8601,
          fiscal_year: record.fiscal_year,
          fiscal_quarter: record.fiscal_quarter,
          is_derived: record.is_derived,
          confidence: record.confidence&.to_f,
          meta: record.meta,
          ttl_seconds: record.ttl_seconds,
          fresh: record.fresh?(now)
        }
      end

      def normalize_list(value, downcase: true)
        return nil if value.blank?

        value.to_s.split(',').map do |entry|
          token = entry.strip
          token = token.downcase if downcase
          token
        end.reject(&:blank?)
      end

      def normalize_ticker(value)
        value.to_s.strip.upcase.presence
      end

      def normalize_metric(value)
        value.to_s.strip.downcase.presence
      end

      def normalize_period_type(value)
        value.to_s.strip.downcase.presence
      end

      def enqueue_refresh_if_needed(ticker:, metrics:, payload:, refresh:, period_type:, history:, limit:)
        return { requested: false, enqueued: [] } unless refresh
        return { requested: true, enqueued: [], reason: 'metrics_required' } if metrics.blank?

        stale_or_missing = metrics.select do |metric|
          entry = payload.find { |row| row[:metric] == metric }
          entry.nil? || entry[:fresh] == false
        end

        return { requested: true, enqueued: [], reason: 'all_fresh' } if stale_or_missing.empty?

        enqueued = TickerMetricsRefreshService.enqueue_refresh(
          ticker: ticker,
          metrics: stale_or_missing,
          period_type: period_type,
          history: history,
          limit: limit
        )

        { requested: true, enqueued: enqueued, stale: stale_or_missing }
      end

      def parse_numeric(value, allow_nil: false)
        return nil if value.nil?
        return value if value.is_a?(Numeric)

        Float(value)
      rescue ArgumentError, TypeError
        allow_nil ? nil : nil
      end

      def parse_integer(value, allow_nil: false)
        return nil if value.nil?
        return value if value.is_a?(Integer)

        Integer(value)
      rescue ArgumentError, TypeError
        allow_nil ? nil : nil
      end

      def parse_date(value)
        return nil if value.blank?
        return value if value.is_a?(Date)
        return value.to_date if value.is_a?(Time)

        Date.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def parse_timestamp(value)
        return Time.current if value.blank?
        return value if value.is_a?(Time)
        return Time.zone.at(value) if value.is_a?(Numeric)

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
