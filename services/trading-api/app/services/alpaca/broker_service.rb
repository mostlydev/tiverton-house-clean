# frozen_string_literal: true

module Alpaca
  class BrokerService
    class AlpacaError < StandardError; end
    class OrderError < AlpacaError; end
    class QuoteError < AlpacaError; end
    class BarError < AlpacaError; end
    class PositionError < AlpacaError; end
    class CorporateActionError < AlpacaError; end

    def initialize
      @client = alpaca_client_class.new(
        endpoint: alpaca_endpoint,
        key_id: ENV.fetch("ALPACA_API_KEY"),
        key_secret: ENV.fetch("ALPACA_SECRET_KEY")
      )
    end

    # Create an order on Alpaca
    # Returns: { success: true/false, order_id:, qty_filled:, avg_fill_price:, filled_value:, status:, error: }
    def create_order(ticker:, side:, qty: nil, notional: nil, order_type: "market", asset_class: "us_equity", **params)
      validate_order_params!(
        ticker: ticker,
        side: side,
        qty: qty,
        notional: notional,
        order_type: order_type,
        asset_class: asset_class,
        extended_hours: params[:extended_hours]
      )

      order_params = build_order_params(
        ticker: ticker,
        side: side,
        qty: qty,
        notional: notional,
        order_type: order_type,
        asset_class: asset_class,
        **params
      )

      order = submit_order(order_params)

      {
        success: true,
        order_id: order.id,
        qty_filled: order.filled_qty&.to_f || 0,
        avg_fill_price: order.filled_avg_price&.to_f || 0,
        filled_value: (order.filled_qty&.to_f || 0) * (order.filled_avg_price&.to_f || 0),
        status: order.status,
        fill_ready: order.status == "filled"
      }
    rescue StandardError => e
      Rails.logger.error("Alpaca order creation failed: #{e.message}")
      {
        success: false,
        error: "Order creation failed: #{e.message}",
        exception: e.class.name
      }
    end

    # Close a position via REST API
    # Includes multi-agent isolation check before closing
    def close_position(ticker:, agent_id: nil)
      # If agent_id provided, verify multi-agent isolation
      if agent_id
        check_multi_agent_isolation!(ticker, agent_id)
      end

      # Close position via REST API DELETE
      response = @client.close_position(symbol: ticker)

      # Response may be Order or Position object depending on gem version
      order_id = response.respond_to?(:id) ? response.id : "close_#{ticker}_#{Time.now.to_i}"
      qty = response.respond_to?(:qty) ? response.qty : (response.respond_to?(:filled_qty) ? response.filled_qty : 0)
      status = response.respond_to?(:status) ? response.status : "closed"

      {
        success: true,
        order_id: order_id,
        qty_closed: qty&.to_f || 0,
        status: status
      }
    rescue StandardError => e
      Rails.logger.error("Alpaca position close failed for #{ticker}: #{e.message}")
      {
        success: false,
        error: "Position close failed: #{e.message}",
        exception: e.class.name
      }
    end

    # Get quote for a ticker (fallback price when fill price unavailable)
    def get_quote(ticker:, side: "BUY", quiet: false, asset_class: "us_equity")
      symbol = ticker.to_s.upcase
      side = side.to_s.upcase

      quote_data = fetch_latest_quote(symbol, asset_class: asset_class)
      last_trade = quote_data[:last]

      bid = quote_data[:bid]
      ask = quote_data[:ask]

      price = if side == "SELL"
                bid || ask || last_trade
      else
                ask || bid || last_trade
      end

      raise QuoteError, "No quote data returned" if price.nil? || price.to_f <= 0

      {
        success: true,
        price: price.to_f,
        bid: bid&.to_f,
        ask: ask&.to_f,
        last: last_trade&.to_f
      }
    rescue StandardError => e
      message = "Alpaca quote fetch failed for #{ticker}: #{e.message}"
      if quiet
        Rails.logger.warn(message)
      else
        Rails.logger.error(message)
      end
      {
        success: false,
        error: "Quote fetch failed: #{e.message}",
        exception: e.class.name
      }
    end

    # Get latest minute bar for a ticker.
    # Returns: { success: true/false, open:, high:, low:, close:, volume:, trade_count:, vwap:, timestamp:, error: }
    def get_latest_bar(ticker:, quiet: false, asset_class: "us_equity")
      symbol = ticker.to_s.upcase
      bar = fetch_latest_bar_data(symbol, asset_class: asset_class)

      raise BarError, "No bar data returned" unless bar.is_a?(Hash)

      close = decimal_value(bar["c"] || bar["close"])
      raise BarError, "No bar close returned" if close.nil? || close <= 0

      {
        success: true,
        open: decimal_value(bar["o"] || bar["open"]),
        high: decimal_value(bar["h"] || bar["high"]),
        low: decimal_value(bar["l"] || bar["low"]),
        close: close,
        volume: decimal_value(bar["v"] || bar["volume"]),
        trade_count: integer_value(bar["n"] || bar["trade_count"]),
        vwap: decimal_value(bar["vw"] || bar["vwap"]),
        timestamp: bar["t"] || bar["timestamp"]
      }
    rescue StandardError => e
      message = "Alpaca bar fetch failed for #{ticker}: #{e.message}"
      if quiet
        Rails.logger.warn(message)
      else
        Rails.logger.error(message)
      end
      {
        success: false,
        error: "Bar fetch failed: #{e.message}",
        exception: e.class.name
      }
    end

    # Get historical bars for a ticker.
    # Returns: { success: true/false, bars: [...], next_page_token:, error: }
    def get_historical_bars(ticker:, start_time:, end_time:, timeframe: "1Min", limit: 10_000, page_token: nil, quiet: false, asset_class: "us_equity")
      symbol = ticker.to_s.upcase
      payload = fetch_historical_bar_data(
        symbol,
        start_time: start_time,
        end_time: end_time,
        timeframe: timeframe,
        limit: limit,
        page_token: page_token,
        asset_class: asset_class
      )

      raise BarError, "No historical bar data returned" unless payload.is_a?(Hash)

      {
        success: true,
        bars: normalize_historical_bars(payload),
        next_page_token: payload["next_page_token"]
      }
    rescue StandardError => e
      message = "Alpaca historical bars fetch failed for #{ticker}: #{e.message}"
      if quiet
        Rails.logger.warn(message)
      else
        Rails.logger.error(message)
      end
      {
        success: false,
        error: "Historical bars fetch failed: #{e.message}",
        exception: e.class.name
      }
    end

    # Get order status from Alpaca
    def get_order_status(order_id:)
      order = @client.order(id: order_id)

      {
        success: true,
        order_id: order.id,
        status: order.status,
        qty_filled: order.filled_qty&.to_f || 0,
        avg_fill_price: order.filled_avg_price&.to_f || 0,
        filled_at: order.filled_at,
        submitted_at: order.submitted_at,
        updated_at: order.updated_at
      }
    rescue StandardError => e
      Rails.logger.error("Alpaca order status fetch failed for #{order_id}: #{e.message}")
      {
        success: false,
        error: "Order status fetch failed: #{e.message}",
        exception: e.class.name
      }
    end

    # Cancel an order on Alpaca
    def cancel_order(order_id:)
      @client.cancel_order(id: order_id)

      {
        success: true,
        order_id: order_id
      }
    rescue StandardError => e
      Rails.logger.error("Alpaca order cancel failed for #{order_id}: #{e.message}")
      {
        success: false,
        error: "Order cancel failed: #{e.message}",
        exception: e.class.name
      }
    end

    # Get all open positions
    def get_positions
      positions = @client.positions

      positions.map do |position|
        asset_class = if position.respond_to?(:asset_class)
                        position.asset_class
        else
                        infer_asset_class(position.symbol)
        end
        {
          ticker: position.symbol,
          qty: position.qty&.to_f || 0,
          avg_entry_price: position.avg_entry_price&.to_f || 0,
          current_price: position.current_price&.to_f || 0,
          market_value: position.market_value&.to_f || 0,
          cost_basis: position.cost_basis&.to_f || 0,
          unrealized_pl: position.unrealized_pl&.to_f || 0,
          asset_class: asset_class.to_s
        }
      end
    rescue StandardError => e
      Rails.logger.error("Alpaca positions fetch failed: #{e.message}")
      []
    end

    # Get current broker-reported position quantity for a ticker.
    # Returns Float qty or nil when unavailable.
    def get_position_qty(ticker:)
      # Alpaca position API requires slash-free crypto symbols (e.g. ETHUSD not ETH/USD)
      symbol = ticker.to_s.delete("/")
      position = @client.position(symbol: symbol)
      position&.qty&.to_f
    rescue StandardError => e
      Rails.logger.warn("Alpaca position qty fetch failed for #{ticker}: #{e.message}")
      nil
    end

    # Get account information
    def get_account
      account = @client.account

      {
        success: true,
        cash: account.cash&.to_f || 0,
        portfolio_value: account.portfolio_value&.to_f || 0,
        buying_power: account.buying_power&.to_f || 0,
        equity: account.equity&.to_f || 0
      }
    rescue StandardError => e
      Rails.logger.error("Alpaca account fetch failed: #{e.message}")
      {
        success: false,
        error: "Account fetch failed: #{e.message}"
      }
    end

    # Get set of active US equity symbols for watchlist validation.
    # Returns Set or nil when unavailable.
    def get_asset_symbols(asset_class: "us_equity")
      assets = @client.assets(status: "active", asset_class: asset_class)
      assets.map(&:symbol).to_set
    rescue StandardError => e
      Rails.logger.warn("Alpaca assets fetch failed: #{e.message}")
      nil
    end

    # Get account activities (fills, dividends, fees, etc.) from Alpaca
    # activity_types: Array of types like ['FILL', 'DIV', 'FEE', 'INT', 'CSD', 'CSW']
    # Returns: { success: true/false, activities: [...], next_page_token:, error: }
    def get_activities(activity_types: nil, since: nil, until_time: nil, page_token: nil, page_size: 100)
      url = "#{alpaca_endpoint}/v2/account/activities"

      params = { page_size: page_size }
      params[:activity_type] = activity_types.join(",") if activity_types&.any?
      params[:after] = since.iso8601 if since
      params[:until] = until_time.iso8601 if until_time
      params[:page_token] = page_token if page_token

      response = Faraday.get(url, params) do |req|
        alpaca_headers.each { |k, v| req.headers[k] = v }
      end

      unless response.success?
        error_body = begin
          JSON.parse(response.body)
        rescue StandardError
          response.body
        end
        return {
          success: false,
          error: "Activities fetch failed: #{response.status} - #{error_body}"
        }
      end

      activities = JSON.parse(response.body)
      next_page_token = response.headers["X-Page-Token"]

      {
        success: true,
        activities: activities.map { |a| normalize_activity(a) },
        next_page_token: next_page_token
      }
    rescue StandardError => e
      Rails.logger.error("Alpaca activities fetch failed: #{e.message}")
      {
        success: false,
        error: "Activities fetch failed: #{e.message}",
        exception: e.class.name
      }
    end

    # Get upcoming corporate actions such as cash dividends.
    # Returns: { success: true/false, actions: [...], error: }
    def get_corporate_actions(symbols:, types: ['cash_dividend'], start_date: Date.current, end_date: 6.months.from_now.to_date)
      symbols = Array(symbols).map { |symbol| symbol.to_s.strip.upcase }.reject(&:blank?).uniq
      raise CorporateActionError, 'symbols are required' if symbols.empty?

      url = "#{alpaca_data_endpoint}/v1/corporate-actions"
      params = {
        symbols: symbols.join(','),
        types: Array(types).join(','),
        since: start_date.to_date.iso8601,
        until: end_date.to_date.iso8601
      }

      response = Faraday.get(url, params) do |req|
        alpaca_headers.each { |k, v| req.headers[k] = v }
      end

      unless response.success?
        return {
          success: false,
          error: "Corporate actions fetch failed: #{response.status}"
        }
      end

      {
        success: true,
        actions: normalize_corporate_actions(JSON.parse(response.body))
      }
    rescue StandardError => e
      Rails.logger.error("Alpaca corporate actions fetch failed: #{e.message}")
      {
        success: false,
        error: "Corporate actions fetch failed: #{e.message}",
        exception: e.class.name
      }
    end

    # Get order with fill details (includes executed fills)
    def get_order_with_fills(order_id:)
      url = "#{alpaca_endpoint}/v2/orders/#{order_id}"
      response = Faraday.get(url) do |req|
        alpaca_headers.each { |k, v| req.headers[k] = v }
      end

      unless response.success?
        return {
          success: false,
          error: "Order fetch failed: #{response.status}"
        }
      end

      order = JSON.parse(response.body)
      {
        success: true,
        order_id: order["id"],
        client_order_id: order["client_order_id"],
        status: order["status"],
        symbol: order["symbol"],
        side: order["side"],
        qty: order["qty"]&.to_f,
        filled_qty: order["filled_qty"]&.to_f,
        filled_avg_price: order["filled_avg_price"]&.to_f,
        order_type: order["type"],
        time_in_force: order["time_in_force"],
        submitted_at: order["submitted_at"],
        filled_at: order["filled_at"],
        legs: order["legs"] # For bracket/OCO orders
      }
    rescue StandardError => e
      {
        success: false,
        error: "Order fetch failed: #{e.message}"
      }
    end

    private

    def normalize_corporate_actions(payload)
      actions = if payload.is_a?(Hash)
                  payload['corporate_actions'] || payload['cash_dividends'] || payload['actions'] || []
      elsif payload.is_a?(Array)
                  payload
      else
                  []
      end

      Array(actions).filter_map do |action|
        next unless action.is_a?(Hash)

        {
          id: action['id'] || action['ca_id'],
          symbol: action['symbol'] || action['ticker'],
          type: action['ca_type'] || action['type'],
          subtype: action['ca_sub_type'] || action['subtype'],
          declaration_date: parse_action_date(action['declaration_date'] || action['declared_date']),
          ex_date: parse_action_date(action['ex_date']),
          record_date: parse_action_date(action['record_date']),
          pay_date: parse_action_date(action['payable_date'] || action['pay_date'] || action['payment_date']),
          cash: decimal_value(action['cash'] || action['cash_amount'] || action['rate'] || action['dividend']),
          raw: action
        }
      end
    end

    def normalize_activity(activity)
      {
        id: activity["id"],
        activity_type: activity["activity_type"],
        transaction_time: activity["transaction_time"],
        symbol: activity["symbol"],
        side: activity["side"],
        qty: activity["qty"]&.to_f,
        price: activity["price"]&.to_f,
        net_amount: activity["net_amount"]&.to_f,
        order_id: activity["order_id"],
        cum_qty: activity["cum_qty"]&.to_f,
        leaves_qty: activity["leaves_qty"]&.to_f,
        description: activity["description"],
        status: activity["status"],
        per_share_amount: activity["per_share_amount"]&.to_f
      }
    end

    def alpaca_endpoint
      # Use paper trading endpoint by default, production if explicitly set
      if AppConfig.alpaca_env == "production"
        "https://api.alpaca.markets"
      else
        "https://paper-api.alpaca.markets"
      end
    end

    def alpaca_client_class
      if defined?(::Alpaca::Trade::Api::Client)
        ::Alpaca::Trade::Api::Client
      elsif defined?(::Alpaca::Trade::Api) && ::Alpaca::Trade::Api.respond_to?(:new)
        ::Alpaca::Trade::Api
      else
        raise AlpacaError, "Alpaca client class not available"
      end
    end

    def alpaca_data_endpoint
      AppConfig.alpaca_data_endpoint
    end

    def alpaca_data_feed
      AppConfig.alpaca_data_feed
    end

    def alpaca_headers
      {
        "APCA-API-KEY-ID" => ENV.fetch("ALPACA_API_KEY"),
        "APCA-API-SECRET-KEY" => ENV.fetch("ALPACA_SECRET_KEY")
      }
    end

    def fetch_latest_quote(symbol, asset_class: "us_equity")
      quote = fetch_latest_quote_data(symbol, asset_class: asset_class)
      last_trade = nil

      if quote.nil? || (quote[:bid].to_f <= 0 && quote[:ask].to_f <= 0)
        last_trade = fetch_latest_trade_price(symbol, asset_class: asset_class)
      end

      {
        bid: quote&.fetch(:bid, nil),
        ask: quote&.fetch(:ask, nil),
        last: last_trade
      }
    end

    def fetch_latest_quote_data(symbol, asset_class: "us_equity")
      if crypto_like?(asset_class)
        quote = fetch_quote_payload("#{alpaca_data_endpoint}/v1beta3/crypto/us/quotes/latest",
                                    { symbols: symbol })
        quote ||= fetch_quote_payload("#{alpaca_data_endpoint}/v1beta3/crypto/us/#{symbol}/quotes/latest",
                                      {})
        quote ||= fetch_quote_payload("#{alpaca_data_endpoint}/v2/crypto/quotes/latest",
                                      { symbols: symbol })
        quote ||= fetch_quote_payload("#{alpaca_data_endpoint}/v2/crypto/#{symbol}/quotes/latest",
                                      {})
      elsif asset_class == "us_option"
        params = { symbols: symbol }
        params[:feed] = alpaca_options_data_feed if alpaca_options_data_feed.present?
        quote = fetch_quote_payload("#{alpaca_data_endpoint}/v1beta1/options/quotes/latest",
                                    params)
        quote ||= fetch_quote_payload("#{alpaca_data_endpoint}/v1beta1/options/#{symbol}/quotes/latest",
                                      params.slice(:feed))
      else
        quote = fetch_quote_payload("#{alpaca_data_endpoint}/v2/stocks/quotes/latest",
                                    { symbols: symbol, feed: alpaca_data_feed })
        if quote.nil? && alpaca_data_feed.present?
          quote = fetch_quote_payload("#{alpaca_data_endpoint}/v2/stocks/quotes/latest",
                                      { symbols: symbol })
        end
        quote ||= fetch_quote_payload("#{alpaca_data_endpoint}/v2/stocks/#{symbol}/quotes/latest",
                                      { feed: alpaca_data_feed })
        if quote.nil? && alpaca_data_feed.present?
          quote = fetch_quote_payload("#{alpaca_data_endpoint}/v2/stocks/#{symbol}/quotes/latest",
                                      {})
        end
      end
      return nil unless quote

      {
        bid: quote["bp"] || quote["bid_price"] || quote["bid"],
        ask: quote["ap"] || quote["ask_price"] || quote["ask"]
      }
    rescue StandardError
      nil
    end

    def fetch_latest_trade_price(symbol, asset_class: "us_equity")
      if crypto_like?(asset_class)
        trade = fetch_trade_payload("#{alpaca_data_endpoint}/v1beta3/crypto/us/trades/latest",
                                    { symbols: symbol })
        trade ||= fetch_trade_payload("#{alpaca_data_endpoint}/v1beta3/crypto/us/#{symbol}/trades/latest",
                                      {})
        trade ||= fetch_trade_payload("#{alpaca_data_endpoint}/v2/crypto/trades/latest",
                                      { symbols: symbol })
        trade ||= fetch_trade_payload("#{alpaca_data_endpoint}/v2/crypto/#{symbol}/trades/latest",
                                      {})
      elsif asset_class == "us_option"
        params = { symbols: symbol }
        params[:feed] = alpaca_options_data_feed if alpaca_options_data_feed.present?
        trade = fetch_trade_payload("#{alpaca_data_endpoint}/v1beta1/options/trades/latest",
                                    params)
        trade ||= fetch_trade_payload("#{alpaca_data_endpoint}/v1beta1/options/#{symbol}/trades/latest",
                                      params.slice(:feed))
      else
        trade = fetch_trade_payload("#{alpaca_data_endpoint}/v2/stocks/trades/latest",
                                    { symbols: symbol, feed: alpaca_data_feed })
        if trade.nil? && alpaca_data_feed.present?
          trade = fetch_trade_payload("#{alpaca_data_endpoint}/v2/stocks/trades/latest",
                                      { symbols: symbol })
        end
        trade ||= fetch_trade_payload("#{alpaca_data_endpoint}/v2/stocks/#{symbol}/trades/latest",
                                      { feed: alpaca_data_feed })
        if trade.nil? && alpaca_data_feed.present?
          trade = fetch_trade_payload("#{alpaca_data_endpoint}/v2/stocks/#{symbol}/trades/latest",
                                      {})
        end
      end
      return nil unless trade

      trade["p"] || trade["price"] || trade["last"]
    rescue StandardError
      nil
    end

    def fetch_latest_bar_data(symbol, asset_class: "us_equity")
      if crypto_like?(asset_class)
        bar = fetch_bar_payload("#{alpaca_data_endpoint}/v1beta3/crypto/us/latest/bars",
                                { symbols: symbol })
        bar ||= fetch_bar_payload("#{alpaca_data_endpoint}/v1beta3/crypto/us/#{symbol}/bars/latest",
                                  {})
      elsif asset_class == "us_option"
        bar = nil
      else
        bar = fetch_bar_payload("#{alpaca_data_endpoint}/v2/stocks/#{symbol}/bars/latest",
                                { feed: alpaca_data_feed })
        if bar.nil? && alpaca_data_feed.present?
          bar = fetch_bar_payload("#{alpaca_data_endpoint}/v2/stocks/#{symbol}/bars/latest",
                                  {})
        end
        bar ||= fetch_bar_payload("#{alpaca_data_endpoint}/v2/stocks/bars/latest",
                                  { symbols: symbol, feed: alpaca_data_feed })
        if bar.nil? && alpaca_data_feed.present?
          bar = fetch_bar_payload("#{alpaca_data_endpoint}/v2/stocks/bars/latest",
                                  { symbols: symbol })
        end
      end

      return nil unless bar

      bar
    rescue StandardError
      nil
    end

    def fetch_historical_bar_data(symbol, start_time:, end_time:, timeframe:, limit:, page_token:, asset_class: "us_equity")
      params = {
        start: start_time.iso8601,
        end: end_time.iso8601,
        timeframe: timeframe,
        limit: limit,
        page_token: page_token,
        sort: "asc"
      }.compact

      if crypto_like?(asset_class)
        payload = fetch_bar_response(
          "#{alpaca_data_endpoint}/v1beta3/crypto/us/#{symbol}/bars",
          params
        )
      elsif asset_class == "us_option"
        payload = nil
      else
        stock_params = params.merge(adjustment: "all", feed: alpaca_data_feed).compact
        payload = fetch_bar_response(
          "#{alpaca_data_endpoint}/v2/stocks/#{symbol}/bars",
          stock_params
        )
        if payload.nil? && alpaca_data_feed.present?
          payload = fetch_bar_response(
            "#{alpaca_data_endpoint}/v2/stocks/#{symbol}/bars",
            params.merge(adjustment: "all")
          )
        end
      end

      payload
    rescue StandardError
      nil
    end

    def fetch_quote_payload(url, params)
      response = Faraday.get(url, params) do |req|
        alpaca_headers.each { |k, v| req.headers[k] = v }
      end

      return nil unless response.success?

      payload = JSON.parse(response.body)
      if payload["quote"].is_a?(Hash)
        payload["quote"]
      elsif payload["quotes"].is_a?(Hash)
        payload["quotes"].values.first
      else
        payload.is_a?(Hash) ? payload : nil
      end
    rescue StandardError => e
      Rails.logger.warn("Alpaca quote payload fetch failed (#{url}): #{e.message}")
      nil
    end

    def fetch_trade_payload(url, params)
      response = Faraday.get(url, params) do |req|
        alpaca_headers.each { |k, v| req.headers[k] = v }
      end

      return nil unless response.success?

      payload = JSON.parse(response.body)
      if payload["trade"].is_a?(Hash)
        payload["trade"]
      elsif payload["trades"].is_a?(Hash)
        payload["trades"].values.first
      else
        payload.is_a?(Hash) ? payload : nil
      end
    rescue StandardError => e
      Rails.logger.warn("Alpaca trade payload fetch failed (#{url}): #{e.message}")
      nil
    end

    def fetch_bar_payload(url, params)
      payload = fetch_bar_response(url, params)
      return nil unless payload

      if payload["bar"].is_a?(Hash)
        payload["bar"]
      elsif payload["bars"].is_a?(Hash)
        payload["bars"].values.first
      else
        payload.is_a?(Hash) ? payload : nil
      end
    rescue StandardError => e
      Rails.logger.warn("Alpaca bar payload fetch failed (#{url}): #{e.message}")
      nil
    end

    def fetch_bar_response(url, params)
      response = Faraday.get(url, params) do |req|
        alpaca_headers.each { |k, v| req.headers[k] = v }
      end

      return nil unless response.success?

      JSON.parse(response.body)
    rescue StandardError => e
      Rails.logger.warn("Alpaca bar response fetch failed (#{url}): #{e.message}")
      nil
    end

    def normalize_historical_bars(payload)
      bars = payload["bars"]
      bars = bars.values.first if bars.is_a?(Hash)
      Array(bars).filter_map do |bar|
        next unless bar.is_a?(Hash)

        close = decimal_value(bar["c"] || bar["close"])
        next if close.nil? || close <= 0

        {
          open: decimal_value(bar["o"] || bar["open"]),
          high: decimal_value(bar["h"] || bar["high"]),
          low: decimal_value(bar["l"] || bar["low"]),
          close: close,
          volume: decimal_value(bar["v"] || bar["volume"]),
          trade_count: integer_value(bar["n"] || bar["trade_count"]),
          vwap: decimal_value(bar["vw"] || bar["vwap"]),
          timestamp: bar["t"] || bar["timestamp"]
        }
      end
    end

    def decimal_value(value)
      return nil if value.nil?

      value.to_f
    end

    def parse_action_date(value)
      return nil if value.blank?

      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def integer_value(value)
      return nil if value.nil?

      value.to_i
    end

    def submit_order(order_params)
      params = order_params.transform_keys(&:to_sym)
      method = @client.method(:new_order)
      if method.parameters.any? { |type, _| type == :keyreq }
        @client.new_order(**params)
      else
        @client.new_order(params)
      end
    end

    def validate_order_params!(ticker:, side:, qty:, notional:, order_type:, asset_class: "us_equity", extended_hours: nil, **)
      raise OrderError, "Ticker is required" if ticker.blank?
      raise OrderError, "Side must be 'buy' or 'sell'" unless %w[buy sell].include?(side.downcase)
      raise OrderError, "Must specify either qty or notional" if qty.nil? && notional.nil?
      raise OrderError, "Cannot specify both qty and notional" if qty && notional
      raise OrderError, "Notional orders must be market orders" if notional && order_type.downcase != "market"
      if crypto_like?(asset_class)
        raise OrderError, "TRAILING_STOP is not supported for crypto orders" if order_type.to_s.downcase == "trailing_stop"
        unless %w[market limit stop_limit].include?(order_type.to_s.downcase)
          raise OrderError, "Unsupported crypto order type: #{order_type}"
        end
      end
      if asset_class == "us_option"
        raise OrderError, "Options do not support extended_hours" if extended_hours == true
        raise OrderError, "Options orders must specify qty (notional orders are not supported)" if notional
        unless %w[market limit stop stop_limit].include?(order_type.to_s.downcase)
          raise OrderError, "Unsupported options order type: #{order_type}"
        end
      end
    end

    def build_order_params(ticker:, side:, qty:, notional: nil, order_type: "market", limit_price: nil, stop_price: nil, trail_percent: nil, trail_amount: nil, time_in_force: nil, extended_hours: nil, asset_class: "us_equity", **extra_params)
      # Determine if we are in pre-market/after-hours (equities only)
      now_et = Time.now.in_time_zone("America/New_York")
      is_pre_market = now_et.hour < 9 || (now_et.hour == 9 && now_et.min < 30)
      is_after_hours = now_et.hour >= 16

      # Default TIF logic
      tif = (time_in_force || default_time_in_force).downcase

      if asset_class == "us_option"
        raise OrderError, "Options do not support extended_hours" if extended_hours == true
        raise OrderError, "Options orders must specify qty (notional orders are not supported)" if notional.present?
        tif = "day"
      elsif crypto_like?(asset_class)
        tif = "gtc"
      else
        # Auto-convert Market orders in pre-market to OPG (Market-on-Open)
        # This allows them to queue for the open instead of being rejected.
        if order_type.downcase == "market" && is_pre_market && !extended_hours
          tif = "opg"
        end
        tif = "day" if notional.present? && tif != "day"
      end

      params = {
        symbol: ticker,
        side: side.downcase,
        type: order_type.downcase,
        time_in_force: tif
      }

      # Handle extended hours
      params[:extended_hours] = true if extended_hours == true && !crypto_like?(asset_class) && asset_class != "us_option"

      # Include any extra params passed in
      params.merge!(extra_params)

      # Quantity or notional
      if qty
        # Preserve fractional shares (common when positions were built from notional orders)
        params[:qty] = qty.to_f
      elsif notional
        params[:notional] = notional.to_f
      end

      # Order type specific params
      params[:limit_price] = limit_price.to_f if limit_price
      params[:stop_price] = stop_price.to_f if stop_price
      params[:trail_percent] = trail_percent.to_f if trail_percent
      params[:trail_amount] = trail_amount.to_f if trail_amount

      params
    end

    def default_time_in_force
      AppConfig.alpaca_time_in_force.to_s.downcase
    end

    def infer_asset_class(symbol)
      return "crypto" if symbol.to_s.include?("/")
      return "us_option" if option_symbol?(symbol)

      "us_equity"
    end

    def option_symbol?(symbol)
      symbol.to_s.match?(/\A[A-Z]{1,6}\d{6}[CP]\d{8}\z/)
    end

    def crypto_like?(asset_class)
      %w[crypto crypto_perp].include?(asset_class)
    end

    def alpaca_options_data_feed
      AppConfig.alpaca_options_data_feed
    end

    # Check if multiple agents hold positions in the same ticker
    # Prevents REST position close when other agents have positions
    def check_multi_agent_isolation!(ticker, agent_id_or_string)
      # Handle both integer database ID and string agent_id
      agent = if agent_id_or_string.is_a?(String)
                Agent.find_by(agent_id: agent_id_or_string)
      else
                Agent.find(agent_id_or_string)
      end

      raise PositionError, "Agent not found: #{agent_id_or_string}" unless agent

      other_agents_positions = Position.where(ticker: ticker)
                                       .where.not(agent_id: agent.id)
                                       .where("qty != 0")

      if other_agents_positions.exists?
        agent_ids = other_agents_positions.joins(:agent).pluck("agents.agent_id").join(", ")
        raise PositionError, "Cannot close position via REST API - other agents hold #{ticker}: #{agent_ids}. Use qty-based order instead."
      end
    end
  end
end
