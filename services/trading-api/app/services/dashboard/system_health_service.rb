# frozen_string_literal: true

module Dashboard
  class SystemHealthService
    SYNC_LOG = Rails.root.join("<legacy-shared-root>/logs/sync.log")
    OPENCLAW_CONFIG = Rails.root.join("../.openclaw/openclaw.json")

    def self.check
      new.check
    end

    def check
      checks = []

      # Gateway check
      checks << check_gateway

      # Database check
      checks << check_database

      # News check
      checks << check_news

      # Sync log check
      checks << check_sync

      # Discord check
      checks << check_discord

      overall = determine_overall(checks)

      { checks: checks, overall: overall }
    end

    private

    def check_gateway
      if containerized_runtime?
        return { name: "Gateway", status: "unknown", message: "Pod-managed" }
      end

      active = `systemctl --user is-active openclaw-gateway 2>/dev/null`.strip == "active"

      if active
        pid = `systemctl --user show openclaw-gateway --property=MainPID --value 2>/dev/null`.strip.to_i
        { name: "Gateway", status: "ok", message: pid > 0 ? "PID #{pid}" : "Running" }
      else
        { name: "Gateway", status: "error", message: "Not running" }
      end
    rescue StandardError
      { name: "Gateway", status: "warning", message: "Unknown" }
    end

    def check_database
      agent_count = Agent.count
      { name: "Database", status: "ok", message: "#{agent_count} agents" }
    rescue StandardError => e
      { name: "Database", status: "error", message: "Error: #{e.message}" }
    end

    def check_news
      today_start = Time.current.beginning_of_day
      news_count = NewsArticle.where("published_at >= ?", today_start).count
      { name: "News", status: "ok", message: "#{news_count} today" }
    rescue StandardError
      { name: "News", status: "warning", message: "API error" }
    end

    def check_sync
      return { name: "Sync", status: "warning", message: "No log" } unless SYNC_LOG.exist?

      mtime = File.mtime(SYNC_LOG)
      age_minutes = ((Time.current - mtime) / 60).to_i
      status = age_minutes < 10 ? "ok" : "warning"

      { name: "Sync", status: status, message: "#{age_minutes}m ago" }
    rescue StandardError
      { name: "Sync", status: "warning", message: "Unknown" }
    end

    def check_discord
      return { name: "Discord", status: "unknown", message: "No config" } unless OPENCLAW_CONFIG.exist?

      config = JSON.parse(OPENCLAW_CONFIG.read)
      discord_cfg = config.dig("channels", "discord") || {}

      if discord_cfg["accounts"].present?
        { name: "Discord", status: "ok", message: "Enabled" }
      else
        { name: "Discord", status: "unknown", message: "Disabled" }
      end
    rescue StandardError
      { name: "Discord", status: "warning", message: "Unknown" }
    end

    def determine_overall(checks)
      statuses = checks.map { |c| c[:status] }

      if statuses.include?("error")
        "error"
      elsif statuses.include?("warning")
        "warning"
      else
        "healthy"
      end
    end

    def containerized_runtime?
      File.exist?("/.dockerenv")
    end
  end
end
