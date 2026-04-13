# frozen_string_literal: true

class TrackedEquityTickersService
  ETF_TICKERS = %w[
    GLD XLI XLE XLV IWM ITA KRE SPY QQQ DIA XLK XLF XLP XLU XLB XLRE XLC
  ].to_set.freeze

  def call
    (position_tickers + watchlist_tickers)
      .map { |ticker| normalize_ticker(ticker) }
      .reject(&:blank?)
      .reject { |ticker| etf?(ticker) || crypto_like?(ticker) }
      .uniq
      .sort
  end

  private

  def position_tickers
    Position
      .where('qty > 0')
      .where(asset_class: [nil, 'us_equity'])
      .distinct
      .pluck(:ticker)
  end

  def watchlist_tickers
    Watchlist
      .distinct
      .pluck(:ticker)
  end

  def normalize_ticker(ticker)
    TickerNormalizer.normalize(ticker)
  end

  def etf?(ticker)
    ETF_TICKERS.include?(ticker)
  end

  def crypto_like?(ticker)
    ticker.to_s.include?('/')
  end
end
