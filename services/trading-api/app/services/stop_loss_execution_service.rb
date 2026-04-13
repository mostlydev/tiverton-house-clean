# frozen_string_literal: true

# Automatically executes a stop-loss sell when a position's price crosses its stop.
# Creates a full Trade record, bypasses Tiverton's approval workflow, and executes
# via Alpaca immediately. Posts confirmation to Discord mentioning the owning trader.
class StopLossExecutionService
  THESIS_MARKER = "STOP_LOSS_AUTO"

  attr_reader :position, :current_price, :error

  def initialize(position, current_price:)
    @position = position
    @current_price = current_price
    @error = nil
  end

  def call
    return skip("no agent") unless position.agent

    agent_id = position.agent.agent_id

    if duplicate_in_flight?
      return skip("stop-loss trade already in-flight for #{position.ticker}/#{agent_id}")
    end

    trade = create_trade!
    approve_trade!(trade)
    result = execute_trade!(trade)

    if result.success?
      trade.reload
      notify_executed(trade)
      Rails.logger.info("[StopLossAuto] FILLED #{trade.trade_id} #{position.ticker} for #{agent_id}")
    else
      notify_failed(trade, result.error)
      Rails.logger.error("[StopLossAuto] FAILED #{trade.trade_id} #{position.ticker}: #{result.error}")
    end

    result
  rescue StandardError => e
    @error = e.message
    Rails.logger.error("[StopLossAuto] Exception for #{position.ticker}/#{position.agent&.agent_id}: #{e.class} #{e.message}")
    notify_failed_without_trade(e)
    nil
  end

  private

  def duplicate_in_flight?
    Trade.where(agent_id: position.agent_id, ticker: position.ticker, side: "SELL")
         .where.not(status: %w[FILLED DENIED CANCELLED FAILED PASSED])
         .where("thesis LIKE ?", "%#{THESIS_MARKER}%")
         .exists?
  end

  def create_trade!
    trade = Trade.create!(
      agent: position.agent,
      ticker: position.ticker,
      side: "SELL",
      order_type: "MARKET",
      qty_requested: position.qty.to_f.abs,
      asset_class: infer_asset_class,
      execution_policy: "immediate",
      thesis: "#{THESIS_MARKER}: price $#{format_price(current_price)} hit stop $#{format_price(position.stop_loss)}. SELL_ALL.",
      is_urgent: true,
      extended_hours: false,
      confirmed_at: Time.current,
      approved_by: "stop_loss_auto",
      executed_by: "stop_loss_auto"
    )

    Rails.logger.info("[StopLossAuto] Created trade #{trade.trade_id} for #{position.ticker}")
    trade
  end

  def approve_trade!(trade)
    trade.approve!
    Rails.logger.info("[StopLossAuto] Approved #{trade.trade_id}")
  end

  def execute_trade!(trade)
    service = TradeExecutionService.new(trade, executed_by: "stop_loss_auto")
    service.call
  end

  def notify_executed(trade)
    mention = agent_mention
    qty = trade.qty_filled || trade.qty_requested
    fill_price = trade.avg_fill_price

    message = [
      "[STOP LOSS EXECUTED] #{position.ticker}",
      "#{mention} your stop was triggered.",
      "**Sold #{qty} @ $#{format_price(fill_price)}** (stop was $#{format_price(position.stop_loss)}, price hit $#{format_price(current_price)})",
      "Trade: #{trade.trade_id}"
    ].join("\n")

    DiscordService.post_to_trading_floor(content: message)
  end

  def notify_failed(trade, error_message)
    mention = agent_mention

    message = [
      "[STOP LOSS FAILED] #{position.ticker}",
      "#{mention} auto-stop execution failed: #{error_message}",
      "Price $#{format_price(current_price)} hit stop $#{format_price(position.stop_loss)}",
      "Trade: #{trade.trade_id}",
      "**Manual action required.**"
    ].join("\n")

    DiscordService.post_to_trading_floor(content: message)
  end

  def notify_failed_without_trade(exception)
    mention = agent_mention

    message = [
      "[STOP LOSS FAILED] #{position.ticker}",
      "#{mention} auto-stop could not create trade: #{exception.message}",
      "Price $#{format_price(current_price)} hit stop $#{format_price(position.stop_loss)}",
      "**Manual action required.**"
    ].join("\n")

    DiscordService.post_to_trading_floor(content: message)
  rescue StandardError => e
    Rails.logger.error("[StopLossAuto] Discord notification also failed: #{e.message}")
  end

  def agent_mention
    agent_id = position.agent.agent_id
    discord_id = News::AgentMentions.discord_id_for(agent_id)
    discord_id ? "<@#{discord_id}> (#{agent_id})" : agent_id
  end

  def infer_asset_class
    ticker = position.ticker.to_s
    return "crypto" if ticker.include?("/")
    return "us_option" if ticker.match?(/\A[A-Z]{1,6}\d{6}[CP]\d{8}\z/)

    "us_equity"
  end

  def format_price(value)
    return "0.00" if value.nil?

    format("%.2f", value.to_f)
  end

  def skip(reason)
    Rails.logger.info("[StopLossAuto] Skipped: #{reason}")
    nil
  end
end
