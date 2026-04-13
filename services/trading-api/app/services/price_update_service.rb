# frozen_string_literal: true

class PriceUpdateService
  BENCHMARK_TICKERS = %w[SPY QQQ].freeze

  attr_reader :updated_tickers

  def initialize(source: 'price_update')
    @source = source
    @updated_tickers = []
  end

  def call
    market_data_active = MarketHours.market_data_active?
    position_records = Position.open_positions.distinct.pluck(:ticker, :asset_class).map do |ticker, asset_class|
      [normalize_ticker(ticker), asset_class]
    end
    position_tickers = position_records.map(&:first)
    position_ticker_set = position_tickers.to_set
    watchlist_tickers = Watchlist.distinct.pluck(:ticker).map { |ticker| normalize_ticker(ticker) }.uniq

    crypto_watchlist = watchlist_tickers.select { |ticker| crypto_ticker?(ticker) }
    equity_watchlist = watchlist_tickers - crypto_watchlist
    benchmark_tickers = market_data_active ? BENCHMARK_TICKERS : []

    has_crypto = position_records.any? { |_, asset| asset == "crypto" } || crypto_watchlist.any?
    return [] unless market_data_active || has_crypto

    tickers = (position_tickers + watchlist_tickers + benchmark_tickers).uniq

    return [] if tickers.empty?

    broker = Alpaca::BrokerService.new
    now = Time.current
    alpaca_positions = broker.get_positions
    position_prices = alpaca_positions.each_with_object({}) do |position, memo|
      price = position[:current_price].to_f
      ticker = normalize_ticker(position[:ticker])
      memo[ticker] = price if price.positive?
    end
    watchlist_only = watchlist_tickers - position_tickers

    eligible_watchlist_equity = filter_watchlist_tickers(broker, watchlist_only & equity_watchlist, asset_class: "us_equity")
    eligible_watchlist_crypto = filter_watchlist_tickers(broker, watchlist_only & crypto_watchlist, asset_class: "crypto")
    eligible_benchmarks = filter_watchlist_tickers(broker, benchmark_tickers, asset_class: "us_equity")
    eligible_tickers = (position_tickers + eligible_watchlist_equity + eligible_watchlist_crypto + eligible_benchmarks).uniq

    asset_class_lookup = {}
    position_records.each { |ticker, asset| asset_class_lookup[ticker] = asset.presence || "us_equity" }
    watchlist_tickers.each do |ticker|
      asset_class_lookup[ticker] ||= if crypto_ticker?(ticker)
                                       "crypto"
                                     elsif option_ticker?(ticker)
                                       "us_option"
                                     else
                                       "us_equity"
                                     end
    end
    benchmark_tickers.each { |ticker| asset_class_lookup[ticker] = "us_equity" }

    eligible_tickers.each do |ticker|
      asset_class = asset_class_lookup[ticker] || (crypto_ticker?(ticker) ? "crypto" : "us_equity")
      next if asset_class == "us_option" && !market_data_active
      quiet = !position_ticker_set.include?(ticker) && !benchmark_tickers.include?(ticker)
      bar = fetch_latest_bar(broker, ticker, asset_class: asset_class, quiet: quiet)
      price = position_prices[ticker] || bar&.dig(:close)
      if price.nil? || price.to_f <= 0
        next if quiet && watchlist_on_cooldown?(ticker)

        result = broker.get_quote(ticker: ticker, side: 'BUY', quiet: quiet, asset_class: asset_class)
        unless result[:success]
          mark_watchlist_cooldown(ticker) if quiet && result[:error].to_s.include?('No quote data returned')
          next
        end
        price = result[:price].presence || result[:last]
      end
      next if price.to_f <= 0

      update_positions_value(ticker, price.to_f, now)
      evaluate_stop_loss_for_ticker(ticker, price.to_f, now)
      record_price_sample(ticker, price.to_f, now, asset_class: asset_class, bar: bar)
      @updated_tickers << ticker
    end

    capture_momentum_metrics if @updated_tickers.any?

    @updated_tickers
  end

  private

  def update_positions_value(ticker, price, timestamp)
    Position.where(ticker: ticker_variants(ticker)).update_all(
      ["current_value = qty * ?, updated_at = ?", price, timestamp]
    )
  end

  def evaluate_stop_loss_for_ticker(ticker, price, timestamp)
    Position.open_positions
            .where(ticker: ticker_variants(ticker))
            .find_each do |position|
      stop_loss = position.stop_loss.to_f
      if stop_loss <= 0
        backfill_missing_position_stop_loss(position, timestamp)
        next
      end

      if stop_loss_hit?(position, price, stop_loss)
        trigger_stop_loss_reminder!(position, price, timestamp) if stop_loss_alert_due?(position, timestamp)
      else
        clear_stop_loss_trigger_state!(position)
      end
    end
  end

  def record_price_sample(ticker, price, timestamp, asset_class:, bar:)
    sample_minute = timestamp.strftime('%Y-%m-%d %H:%M:00')
    PriceSample.upsert(
      {
        ticker: ticker,
        price: price,
        asset_class: asset_class,
        open_price: bar&.dig(:open),
        high_price: bar&.dig(:high),
        low_price: bar&.dig(:low),
        close_price: bar&.dig(:close) || price,
        volume: bar&.dig(:volume),
        trade_count: bar&.dig(:trade_count),
        vwap: bar&.dig(:vwap),
        sampled_at: timestamp,
        sample_minute: sample_minute,
        source: @source,
        created_at: timestamp,
        updated_at: timestamp
      },
      unique_by: :idx_price_samples_unique_minute
    )
  end

  def filter_watchlist_tickers(broker, watchlist, asset_class:)
    return [] if watchlist.empty?

    return watchlist if %w[crypto crypto_perp].include?(asset_class)

    symbols = Rails.cache.fetch("price_update:asset_symbols:#{asset_class}", expires_in: 12.hours) do
      broker.get_asset_symbols(asset_class: asset_class)
    end

    return watchlist if symbols.nil?

    watchlist.select { |ticker| symbols.include?(ticker) }
  rescue StandardError => e
    Rails.logger.warn("PriceUpdate: watchlist filter skipped (#{e.message})")
    watchlist
  end

  def crypto_ticker?(ticker)
    ticker.to_s.include?("/")
  end

  def option_ticker?(ticker)
    ticker.to_s.match?(/\A[A-Z]{1,6}\d{6}[CP]\d{8}\z/)
  end

  def normalize_ticker(ticker)
    TickerNormalizer.normalize(ticker)
  end

  def ticker_variants(ticker)
    variants = [ticker]
    variants << ticker.delete("/") if ticker.to_s.include?("/")
    variants.uniq
  end

  def fetch_latest_bar(broker, ticker, asset_class:, quiet:)
    return nil if asset_class == "us_option"

    result = broker.get_latest_bar(ticker: ticker, asset_class: asset_class, quiet: quiet)
    return nil unless result[:success]

    result
  end

  def capture_momentum_metrics
    MomentumMetricsCaptureService.new(tickers: @updated_tickers).call
  rescue StandardError => e
    Rails.logger.error("PriceUpdate: momentum metric capture failed (#{e.class}: #{e.message})")
  end

  def watchlist_on_cooldown?(ticker)
    key = "price_update:cooldown:#{ticker}"
    if defined?(Sidekiq)
      Sidekiq.redis { |r| r.get(key) } == '1'
    else
      Rails.cache.read(key) == true
    end
  end

  def mark_watchlist_cooldown(ticker)
    key = "price_update:cooldown:#{ticker}"
    if defined?(Sidekiq)
      Sidekiq.redis { |r| r.set(key, '1', ex: 86_400) }
    else
      Rails.cache.write(key, true, expires_in: 24.hours)
    end
  end

  def backfill_missing_position_stop_loss(position, timestamp)
    direction = position.qty.to_f.negative? ? 1.0 : -1.0
    fallback = position.avg_entry_price.to_f * (1.0 + (direction * AppConfig.stop_loss_fallback_percent))
    return unless fallback.positive?

    position.update_columns(
      stop_loss: fallback.round(4),
      updated_at: timestamp
    )
  end

  def stop_loss_hit?(position, price, stop_loss)
    qty = position.qty.to_f
    return false if qty.zero?

    qty.positive? ? price <= stop_loss : price >= stop_loss
  end

  def stop_loss_alert_due?(position, timestamp)
    last_alert_at = position.stop_loss_last_alert_at
    return true if last_alert_at.blank?

    timestamp >= last_alert_at + AppConfig.stop_loss_alert_interval_minutes.minutes
  end

  def trigger_stop_loss_reminder!(position, current_price, timestamp)
    attrs = {
      stop_loss_triggered_at: position.stop_loss_triggered_at || timestamp,
      stop_loss_last_alert_at: timestamp,
      stop_loss_alert_count: position.stop_loss_alert_count.to_i + 1
    }
    position.update_columns(attrs.merge(updated_at: timestamp))

    # Auto-execute the stop loss sell immediately (async to avoid blocking the price loop)
    StopLossExecutionJob.perform_later(position.id, current_price.to_f)
  end

  def clear_stop_loss_trigger_state!(position)
    return if position.stop_loss_triggered_at.blank? && position.stop_loss_last_alert_at.blank? &&
              position.stop_loss_alert_count.to_i.zero?

    position.update_columns(
      stop_loss_triggered_at: nil,
      stop_loss_last_alert_at: nil,
      stop_loss_alert_count: 0,
      updated_at: Time.current
    )
  end
end
