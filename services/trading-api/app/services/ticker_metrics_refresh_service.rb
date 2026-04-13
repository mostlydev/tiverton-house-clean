# frozen_string_literal: true

require 'open3'
require 'timeout'

class TickerMetricsRefreshService
  FALLBACK_LOCK_SECONDS = 120
  FALLBACK_MIN_INTERVAL_SECONDS = {
    apewisdom: 30,
    quiver_wsb: 30,
    fundamentals: 15
  }.freeze

  FETCHERS = {
    apewisdom: {
      prefixes: %w[social_mentions_],
      script: ENV.fetch('APEWISDOM_FETCHER', 'fetch-apewisdom.sh')
    },
    quiver_wsb: {
      prefixes: %w[social_mentions_],
      script: ENV.fetch('QUIVER_WSB_FETCHER', 'fetch-quiver-wsb.sh')
    },
    fundamentals: {
      prefixes: %w[fs_ val_ profit_ growth_ health_],
      script: ENV.fetch('FUNDAMENTALS_FETCHER', 'fetch-fundamentals.sh')
    }
  }.freeze

  class << self
    def enqueue_refresh(ticker:, metrics:, period_type:, history:, limit:)
      requests = build_requests(ticker: ticker, metrics: metrics, period_type: period_type, history: history, limit: limit)
      enqueued = []

      requests.each do |request|
        next unless acquire_fetcher_rate_limit(request)
        next unless acquire_lock(request)

        TickerMetricsRefreshJob.perform_later(request)
        enqueued << request[:fetcher]
      end

      enqueued.uniq
    end

    def run_fetch(request)
      cmd = build_command(request)
      return { status: :skipped, reason: 'no_command' } if cmd.blank?

      stdout = ''
      stderr = ''
      status = nil

      Timeout.timeout(request[:timeout] || 60) do
        stdout, stderr, status = Open3.capture3(*cmd)
      end

      unless status&.success?
        return { status: :error, stderr: stderr.presence || stdout.presence, exitstatus: status&.exitstatus }
      end

      { status: :ok, stdout: stdout.to_s.strip }
    rescue Timeout::Error
      { status: :error, stderr: "timeout after #{request[:timeout] || 60}s" }
    end

    private

    def build_requests(ticker:, metrics:, period_type:, history:, limit:)
      return [] if ticker.blank? || metrics.blank?

      grouped = Hash.new { |hash, key| hash[key] = { metrics: [] } }

      metrics.each do |metric|
        fetcher = fetcher_for_metric(metric)
        next unless fetcher

        grouped[fetcher][:metrics] << metric
      end

      grouped.map do |fetcher, payload|
        build_request(fetcher: fetcher, ticker: ticker, metrics: payload[:metrics], period_type: period_type, history: history, limit: limit)
      end.compact
    end

    def build_request(fetcher:, ticker:, metrics:, period_type:, history:, limit:)
      case fetcher
      when :apewisdom
        window = extract_window(metrics) || '24h'
        {
          fetcher: fetcher,
          ticker: ticker,
          script: FETCHERS.fetch(fetcher).fetch(:script),
          args: [ '--subreddit', 'wallstreetbets', '--window', window ],
          lock_key: "ticker_metrics_refresh:apewisdom:#{window}",
          timeout: 60
        }
      when :quiver_wsb
        window = extract_window(metrics) || '1h'
        {
          fetcher: fetcher,
          ticker: ticker,
          script: FETCHERS.fetch(fetcher).fetch(:script),
          args: [ '--ticker', ticker, '--window', window ],
          lock_key: "ticker_metrics_refresh:quiver:#{ticker}:#{window}",
          timeout: 60
        }
      when :fundamentals
        period = period_type.presence || 'quarterly'
        args = [ ticker, '--period', period ]
        args += [ '--limit', limit.to_s ] if history && limit.to_i > 0
        {
          fetcher: fetcher,
          ticker: ticker,
          script: FETCHERS.fetch(fetcher).fetch(:script),
          args: args,
          lock_key: "ticker_metrics_refresh:fundamentals:#{ticker}:#{period}",
          timeout: 120
        }
      end
    end

    def fetcher_for_metric(metric)
      return nil if metric.blank?

      if metric.start_with?('social_mentions_')
        provider = ENV.fetch('SOCIAL_MENTIONS_PROVIDER', 'apewisdom').to_s.strip.downcase
        return :quiver_wsb if provider == 'quiver'
        return :apewisdom if FETCHERS.key?(:apewisdom)
      end

      FETCHERS.each do |key, config|
        next if key == :apewisdom
        return key if config.fetch(:prefixes).any? { |prefix| metric.start_with?(prefix) }
      end

      nil
    end

    def extract_window(metrics)
      metrics.each do |metric|
        next unless metric.start_with?('social_mentions_')

        suffix = metric.delete_prefix('social_mentions_')
        return suffix if suffix.present?
      end
      nil
    end

    def build_command(request)
      script = request[:script]
      return nil if script.blank? || !File.exist?(script)

      [ script, *Array(request[:args]) ]
    end

    def acquire_lock(request)
      key = request[:lock_key]
      return true if key.blank?

      return false if Rails.cache.read(key)

      lock_seconds = refresh_config("lock_seconds") || FALLBACK_LOCK_SECONDS
      Rails.cache.write(key, true, expires_in: lock_seconds.to_i)
      true
    end

    def acquire_fetcher_rate_limit(request)
      fetcher = request[:fetcher]
      return true if fetcher.blank?

      min_interval = refresh_config("min_interval_seconds", fetcher) ||
                     FALLBACK_MIN_INTERVAL_SECONDS[fetcher.to_sym]
      return true if min_interval.blank? || min_interval.to_i <= 0

      key = "ticker_metrics_refresh:rate_limit:#{fetcher}"
      last = Rails.cache.read(key)
      return false if last.present?

      Rails.cache.write(key, true, expires_in: min_interval.to_i)
      true
    end

    def refresh_config(*keys)
      node = Settings.ticker_metrics&.refresh
      keys.each { |k| node = node&.[](k.to_s) || node&.[](k.to_sym) }
      node
    rescue StandardError
      nil
    end
  end
end
