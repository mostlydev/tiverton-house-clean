# frozen_string_literal: true

module AppConfig
  class << self
    def boolean(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def integer(value)
      value.to_i
    end

    def admin_username
      Settings.admin.username.to_s
    end

    def admin_password
      Settings.admin.password.to_s
    end

    def admin_credentials_configured?
      admin_username.present? && admin_password.present?
    end

    def openrouter_api_key
      Settings.openrouter.api_key
    end

    def news_ai_enabled?
      boolean(Settings.news_ai.enabled)
    end

    def news_ai_model
      Settings.news_ai.model
    end

    def news_ai_max_retries
      integer(Settings.news_ai.max_retries)
    end

    def news_ai_retry_delay_seconds
      integer(Settings.news_ai.retry_delay_seconds)
    end

    def news_ai_timeout_seconds
      integer(Settings.news_ai.timeout_seconds)
    end

    def news_ai_open_timeout_seconds
      integer(Settings.news_ai.open_timeout_seconds)
    end

    def news_ai_temperature
      Settings.news_ai.temperature.to_f
    end

    def news_ai_content_max_length
      integer(Settings.news_ai.content_max_length)
    end

    def news_ai_prompt_template
      Settings.news_ai.prompt_template.to_s
    end

    def news_poll_minutes
      integer(Settings.news_poll.minutes)
    end

    def news_poll_overlap_minutes
      integer(Settings.news_poll.overlap_minutes)
    end

    def news_poll_fetch_limit
      integer(Settings.news_poll.fetch_limit)
    end

    def news_summary_window_minutes
      integer(Settings.news_summary.window_minutes)
    end

    def discord_bot_token
      Settings.discord.bot_token
    end

    def discord_trading_floor_webhook
      Settings.discord.trading_floor_webhook
    end

    def discord_infra_webhook
      Settings.discord.infra_webhook
    end

    def discord_trading_floor_channel_id
      Settings.discord.trading_floor_channel_id
    end

    def discord_infra_channel_id
      Settings.discord.infra_channel_id
    end

    def discord_notification_dedupe_seconds
      integer(Settings.discord.notification_dedupe_seconds)
    end

    def trading_api_internal_token
      Settings.api_auth.internal_token.to_s
    end

    def trading_api_agent_tokens
      agent_tokens = Settings.api_auth.agents
      return {} if agent_tokens.blank?

      agent_tokens.to_h.each_with_object({}) do |(agent_id, token), memo|
        token = token.to_s
        memo[agent_id.to_s] = token if token.present?
      end
    end

    def public_web_hosts
      ENV.fetch("PUBLIC_WEB_HOSTS", "www.tivertonhouse.com")
        .split(",")
        .map(&:strip)
        .reject(&:blank?)
        .map(&:downcase)
        .uniq
    end

    def public_web_host?(host)
      public_web_hosts.include?(host.to_s.downcase)
    end

    def remediation_enabled?
      boolean(Settings.remediation.enabled)
    end

    def remediation_agent
      Settings.remediation.agent
    end

    def remediation_channel_id
      Settings.remediation.channel_id
    end

    def remediation_timeout_seconds
      integer(Settings.remediation.timeout_seconds)
    end

    def remediation_throttle_seconds
      integer(Settings.remediation.throttle_seconds)
    end

    def trades_duplicate_window_seconds
      integer(Settings.trades.duplicate_window_seconds)
    end

    def proposal_failure_cooldown_seconds
      integer(Settings.trades.proposal_failure_cooldown_seconds)
    end

    def trades_stale_execution_timeout
      integer(Settings.trades.stale.execution_timeout_minutes).minutes
    end

    def trades_stale_approval_timeout
      integer(Settings.trades.stale.approval_timeout_minutes).minutes
    end

    def trades_stale_proposal_timeout
      integer(Settings.trades.stale.proposal_timeout_minutes).minutes
    end

    def trades_stale_execution_minutes
      integer(Settings.trades.stale.execution_timeout_minutes)
    end

    def trades_stale_approval_minutes
      integer(Settings.trades.stale.approval_timeout_minutes)
    end

    def trades_stale_proposal_minutes
      integer(Settings.trades.stale.proposal_timeout_minutes)
    end

    def stop_loss_fallback_percent
      Settings.trades.stop_loss_fallback_percent.to_f
    end

    def stop_loss_alert_interval_minutes
      integer(Settings.trades.stop_loss_alert_interval_minutes)
    end

    def outbox_max_attempts
      integer(Settings.outbox.max_attempts)
    end

    def outbox_lock_timeout_minutes
      integer(Settings.outbox.lock_timeout_minutes)
    end

    def market_pre_open_minutes
      integer(Settings.market_hours.pre_market_start_minutes)
    end

    def market_open_minutes
      integer(Settings.market_hours.market_open_minutes)
    end

    def market_close_minutes
      integer(Settings.market_hours.market_close_minutes)
    end

    def market_after_hours_end_minutes
      integer(Settings.market_hours.after_hours_end_minutes)
    end

    def alpaca_env
      Settings.alpaca.env
    end

    def alpaca_data_endpoint
      Settings.alpaca.data_url.presence || Settings.alpaca.data_endpoint
    end

    def alpaca_data_feed
      Settings.alpaca.data_feed
    end

    def alpaca_options_data_feed
      Settings.alpaca.options_data_feed
    end

    def alpaca_time_in_force
      Settings.alpaca.time_in_force
    end

    def wallet_broker_sync_enabled?
      boolean(Settings.wallets.broker_sync_enabled)
    end

    def funded_trader_ids
      Settings.wallets.funded_trader_ids.to_s.split(",").map(&:strip).reject(&:blank?).uniq
    end

    def ticker_metrics_default_ttl_seconds
      integer(Settings.ticker_metrics.default_ttl_seconds || 3600)
    end

    def ticker_metrics_ttl_seconds(metric)
      ttl_map = Settings.ticker_metrics.ttl_seconds
      ttl = ttl_map&.[](metric.to_s) || ttl_map&.[](metric.to_sym)
      integer(ttl || ticker_metrics_default_ttl_seconds)
    end

    def ticker_metrics_label(metric)
      entry = ticker_metrics_label_entry(metric)
      entry&.[]("label") || entry&.[](:label) || metric.to_s
    end

    def ticker_metrics_hint(metric)
      entry = ticker_metrics_label_entry(metric)
      entry&.[]("hint") || entry&.[](:hint)
    end

    def ticker_metrics_format(metric)
      entry = ticker_metrics_label_entry(metric)
      (entry&.[]("format") || entry&.[](:format) || "number").to_s
    end

    def ticker_metrics_labels
      labels_map = Settings.ticker_metrics.labels
      return {} unless labels_map
      labels_map.to_h.transform_keys(&:to_s)
    end

    private

    def ticker_metrics_label_entry(metric)
      labels_map = Settings.ticker_metrics.labels
      return nil unless labels_map
      labels_map[metric.to_s] || labels_map[metric.to_sym]
    end
  end
end
