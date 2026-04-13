# frozen_string_literal: true
require "digest"

module News
  # Posts news directly to Discord with agent mentions.
  # Only posts when at least one article has agent routing.
  # Items without routing are skipped — agents pick up routine news via latest.md.
  class DundasDispatchService
    def initialize(dispatch)
      @dispatch = dispatch
    end

    def call
      analysis = extract_analysis

      unless worth_posting?(analysis)
        @dispatch.update!(
          status: 'confirmed',
          confirmed_at: Time.current,
          response: 'Skipped: no agents routed'
        )
        Rails.logger.info("[NewsDispatch] Skipped batch #{@dispatch.id} (no agent routing)")
        return
      end

      message = build_discord_message(analysis)

      unless allow_dispatch_message?(message)
        @dispatch.update!(
          status: 'confirmed',
          confirmed_at: Time.current,
          response: 'Skipped: duplicate dispatch (deduped)'
        )
        Rails.logger.info("[NewsDispatch] Deduped batch #{@dispatch.id} (identical payload recently sent)")
        return
      end

      DiscordService.post_to_trading_floor(content: message)

      @dispatch.update!(
        status: 'confirmed',
        confirmed_at: Time.current,
        response: 'Posted directly to Discord'
      )

      Rails.logger.info("[NewsDispatch] Posted batch #{@dispatch.id} to Discord with mentions")
    rescue StandardError => e
      @dispatch.update!(status: 'failed', error: e.message)
      Rails.logger.error("[NewsDispatch] Failed to post batch #{@dispatch.id}: #{e.message}")
      raise
    end

    private

    def extract_analysis
      metadata = @dispatch.metadata || {}
      metadata['analysis'] || metadata[:analysis] || {}
    end

    # Post only if at least one article explicitly passed posting gate.
    def worth_posting?(analysis)
      return false unless analysis.is_a?(Hash)

      analysis.any? do |_article_id, data|
        next false unless data.is_a?(Hash)
        next false unless data['success'] || data[:success]

        auto_post = data['auto_post']
        auto_post = data[:auto_post] if auto_post.nil?
        next false unless auto_post == true

        route_to = data['route_to'] || data[:route_to] || []
        route_to.any?
      end
    end

    def build_discord_message(analysis)
      agents_to_mention = extract_agents_to_mention(analysis)

      mentions = agents_to_mention.map { |agent| News::AgentMentions.mention_for(agent) }.compact.join(' ')

      lines = []
      lines << mentions if mentions.present?
      lines << @dispatch.message

      lines.join("\n")
    end

    def extract_agents_to_mention(analysis)
      return [] unless analysis.is_a?(Hash)

      agents = Set.new

      analysis.each do |_article_id, article_analysis|
        data = article_analysis || {}
        route_to = data['route_to'] || data[:route_to] || []

        # Mention agents for routed articles
        route_to.each { |agent| agents.add(agent.to_s.downcase) }
      end

      agents.to_a
    end

    def allow_dispatch_message?(message)
      NotificationDedupeService.allow?(
        dedupe_key(message),
        ttl_seconds: AppConfig.discord_notification_dedupe_seconds
      )
    end

    def dedupe_key(message)
      normalized = message.to_s.gsub(/\s+/, ' ').strip.downcase
      digest = Digest::SHA256.hexdigest(normalized)
      "news_dispatch:trading_floor:#{digest}"
    end
  end
end
