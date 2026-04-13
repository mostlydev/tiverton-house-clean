# frozen_string_literal: true

# Ticker normalization utility for consistent storage across stocks/ETFs/crypto
module TickerNormalizer
  # Normalize ticker to standard format:
  # - Stocks/ETFs: UPPERCASE (AAPL, SPY)
  # - Crypto: ASSET/USD format (BTC/USD, ETH/USD, LINK/USD)
  def self.normalize(ticker)
    return nil if ticker.nil?

    sym = ticker.to_s.strip.upcase
    return sym if sym.empty?

    # If already has slash, keep it
    return sym if sym.include?("/")

    # Convert crypto tickers ending in USD to ASSET/USD format
    # BTCUSD -> BTC/USD, ETHUSD -> ETH/USD, LINKUSD -> LINK/USD
    if sym.end_with?("USD") && sym.length > 3
      base = sym[0..-4]
      return "#{base}/USD"
    end

    # Everything else: plain uppercase
    sym
  end
end
