# frozen_string_literal: true

module Trades
  class RemediationAlertService
    class << self
      def duplicate_submission!(incoming:, existing:, guard:, context: {})
        message = [
          "[SUBMISSION GUARD] Duplicate submission blocked",
          "Guard: #{guard}",
          "Agent: #{incoming[:agent_id]}",
          "Ticker: #{incoming[:ticker]}",
          "Side: #{incoming[:side]}",
          "Incoming payload: #{incoming.inspect}",
          "Existing trade: #{existing[:trade_id]} (#{existing[:status]})",
          "Context: #{context.inspect}"
        ].join("\n")

        notify(message, dedupe_key: "duplicate:#{guard}:#{incoming[:agent_id]}:#{incoming[:ticker]}:#{incoming[:side]}")
      end

      def exception!(scope:, exception:, context: {})
        message = [
          "[SUBMISSION EXCEPTION] #{scope}",
          "Error: #{exception.class}: #{exception.message}",
          "Context: #{context.inspect}"
        ].join("\n")

        notify(message, dedupe_key: "exception:#{scope}:#{exception.class}:#{context[:agent_id]}:#{context[:ticker]}")
      end

      private

      def notify(message, dedupe_key:)
        return unless enabled?
        return if throttled?(dedupe_key)

        notify_agent(message)
        notify_channel(message)
      rescue StandardError => e
        Rails.logger.error("Remediation alert failed: #{e.class}: #{e.message}")
      end

      def notify_agent(message)
        OpenclawService.send_agent_message(
          agent: remediation_agent,
          message: message,
          timeout: timeout_seconds
        )
      rescue StandardError => e
        Rails.logger.error("Remediation agent notify failed: #{e.class}: #{e.message}")
      end

      def notify_channel(message)
        channel_id = remediation_channel
        OpenclawService.send_discord_message(
          channel_id: channel_id,
          message: message,
          timeout: timeout_seconds
        )
      rescue StandardError => e
        Rails.logger.error("Remediation channel notify failed: #{e.class}: #{e.message}")
        DiscordService.post_to_infra(content: message)
      end

      def enabled?
        AppConfig.remediation_enabled?
      end

      def remediation_agent
        AppConfig.remediation_agent
      end

      def remediation_channel
        AppConfig.remediation_channel_id
      end

      def timeout_seconds
        AppConfig.remediation_timeout_seconds
      end

      def throttle_seconds
        AppConfig.remediation_throttle_seconds
      end

      def throttled?(dedupe_key)
        return false if throttle_seconds <= 0

        cache_key = "submission_remediation:#{dedupe_key}"
        cached = Rails.cache.read(cache_key)
        return true if cached

        Rails.cache.write(cache_key, true, expires_in: throttle_seconds.seconds)
        false
      rescue StandardError
        false
      end
    end
  end
end
