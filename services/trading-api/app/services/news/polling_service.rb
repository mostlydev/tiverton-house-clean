# frozen_string_literal: true

module News
  class PollingService
    def initialize(minutes: nil, limit: nil)
      @minutes = (minutes || AppConfig.news_poll_minutes).to_i
      @limit = (limit || AppConfig.news_poll_fetch_limit).to_i
    end

    def call
      fetched_at = Time.current
      start_time, end_time = time_window

      raw_articles = News::AlpacaClient.new.fetch(
        start_time: start_time,
        end_time: end_time,
        limit: @limit
      )

      articles = News::IngestionService.new(raw_articles, fetched_at: fetched_at).call
      return [] if articles.empty?

      # Analyze first to determine impact
      analysis_map = analyze_articles(articles)
      
      # Only write HIGH impact articles to disk
      high_impact_articles = filter_high_impact(articles, analysis_map)
      
      writer = News::FileWriter.new
      writer.write_articles(high_impact_articles) if high_impact_articles.any?
      writer.write_latest_summary(high_impact_articles)

      NewsDundasDispatchJob.perform_later(
        articles.map(&:id),
        analysis: analysis_map,
        metadata: { analysis: analysis_map }
      )
      articles
    end

    private

    def time_window
      overlap_minutes = AppConfig.news_poll_overlap_minutes
      latest = NewsArticle.maximum(:published_at)
      end_time = Time.current
      start_time = if latest
                     latest - overlap_minutes.minutes
      else
                     end_time - @minutes.minutes
      end

      [ start_time, end_time ]
    end

    def filter_high_impact(articles, analysis_map)
      return [] unless analysis_map.is_a?(Hash)
      
      articles.select do |article|
        data = analysis_map[article.id.to_s] || analysis_map[article.id] || {}
        next false unless data['success'] || data[:success]
        
        impact = (data['impact'] || data[:impact]).to_s.upcase
        impact == 'HIGH'
      end
    end

    def analyze_articles(articles)
      return {} unless AppConfig.news_ai_enabled?

      context = News::PortfolioContextService.new.call
      held_map = build_symbol_to_agents(context[:positions] || {})
      watchlist_map = build_watchlist_map(context[:watchlists] || {})
      analysis_map = {}

      articles.each do |article|
        analysis = preclassified_analysis(article) || News::AnalysisService.new(article, context).call
        analysis = apply_gating(article, analysis, held_map, watchlist_map)
        analysis_map[article.id.to_s] = analysis

        if analysis[:success]
          # Keep floor traffic batched in NewsDundasDispatchJob.
          # This avoids duplicate chatter from per-article + batch posting.
        else
          notify_analysis_failure(article, analysis)
        end
      rescue StandardError => e
        analysis_map[article.id.to_s] = { success: false, error: e.message }
        notify_analysis_failure(article, { error: e.message })
      end

      analysis_map
    end

    def preclassified_analysis(article)
      return unless low_signal_roundup?(article)

      Rails.logger.info("News prefilter: skipped AI analysis for low-signal roundup - #{article.headline.to_s.truncate(100)}")

      {
        success: true,
        impact: "LOW",
        route_to: [],
        auto_post: false,
        reasoning: "Skipped AI analysis for broad multi-symbol market-mover roundup."
      }
    end

    def low_signal_roundup?(article)
      headline = ActionView::Base.full_sanitizer.sanitize(article.headline.to_s).gsub(/\s+/, " ").strip
      return false if article.symbols.size < 5

      market_roundup_patterns.any? { |pattern| headline.match?(pattern) }
    end

    def market_roundup_patterns
      @market_roundup_patterns ||= [
        /\b\d+\s+(?:\w+\s+){0,4}stocks moving in\b/i,
        /\bother big stocks moving (?:lower|higher) in\b/i
      ]
    end

    def apply_gating(article, analysis, held_map, watchlist_map)
      return analysis unless analysis[:success]

      impact = analysis[:impact].to_s.upcase
      auto_post = !!analysis[:auto_post]
      route_to = Array(analysis[:route_to]).map { |a| a.to_s.downcase }

      symbols = (article.symbols || []).map { |s| s.to_s.upcase }
      held_agents = symbols.flat_map { |sym| held_map[sym] || [] }.uniq
      watchlist_agents = symbols.flat_map { |sym| watchlist_map[sym] || [] }.uniq

      headline = ActionView::Base.full_sanitizer.sanitize(article.headline.to_s).downcase
      content = ActionView::Base.full_sanitizer.sanitize(article.content_or_summary.to_s).downcase
      macro_hit = macro_hit?(headline, content)
      held_hit = held_agents.any?
      watchlist_hit = watchlist_agents.any?

      # Auto-post gate: HIGH always, MEDIUM only for held/watchlist positions
      if impact == "HIGH"
        auto_post = true if held_hit || macro_hit
      elsif impact == "MEDIUM"
        auto_post = held_hit || watchlist_hit
      else
        auto_post = false
      end

      # Block fluff/hype content even if HIGH impact
      if fluff_content?(headline, content)
        auto_post = false
        Rails.logger.info("News gating: blocked fluff content - #{article.headline.truncate(80)}")
      end

      # Route only to directly affected agents or Dundas for macro/event coverage
      allowed = held_agents
      allowed += watchlist_agents if watchlist_hit
      allowed += [ "dundas" ] if macro_hit
      route_to = route_to.select { |agent| allowed.include?(agent) }.uniq
      route_to = allowed if route_to.empty? && allowed.any?
      auto_post = false if auto_post && allowed.empty?

      analysis.merge(auto_post: auto_post, route_to: route_to)
    end

    def build_symbol_to_agents(positions)
      mapping = Hash.new { |h, k| h[k] = [] }
      positions.each do |agent, tickers|
        tickers.each do |entry|
          symbol = entry.to_s.split.first&.upcase
          mapping[symbol] << agent.to_s.downcase if symbol
        end
      end
      mapping
    end

    def build_watchlist_map(watchlists)
      mapping = Hash.new { |h, k| h[k] = [] }
      watchlists.each do |agent, tickers|
        Array(tickers).each do |symbol|
          next unless symbol
          mapping[symbol.to_s.upcase] << agent.to_s.downcase
        end
      end
      mapping
    end

    # Detect fluff/hype content that should not be auto-posted
    def fluff_content?(headline, content)
      combined = "#{headline} #{content}"

      # Hype/sensationalist keywords
      hype_patterns = [
        "moon", "rocket", "explode", "skyrocket",
        "massive gains", "huge returns", "big money", "get rich",
        "meme stock", "retail investors", "wallstreetbets",
        "you won't believe", "shocking"
      ]

      # Generic market commentary patterns
      generic_patterns = [
        "stocks fell on concerns", "stocks rose on hopes",
        "what to watch", "what you need to know",
        "traders eye", "markets await"
      ]

      # Technical analysis fluff (generic patterns)
      ta_fluff = [
        "bullish pattern", "bearish pattern"
      ]

      all_patterns = hype_patterns + generic_patterns + ta_fluff

      # Check if any pattern matches (case insensitive)
      all_patterns.any? { |pattern| combined.include?(pattern) }
    end

    def macro_keywords
      [
        "fomc",
        "federal reserve",
        "fed",
        "cpi",
        "pce",
        "ppi",
        "nfp",
        "jobs report",
        "nonfarm payroll",
        "unemployment rate",
        "rate hike",
        "rate cut",
        "yield",
        "treasury",
        "inflation",
        "recession",
        "ecb",
        "boj",
        "boe",
        "opec",
        "sanctions",
        "tariff",
        "war",
        "ceasefire",
        "geopolitical",
        "shutdown",
        "debt ceiling",
        "default"
      ]
    end

    def macro_hit?(headline, content)
      combined = "#{headline} #{content}"
      macro_patterns.any? { |pattern| combined.match?(pattern) }
    end

    def macro_patterns
      @macro_patterns ||= macro_keywords.map { |keyword| keyword_pattern(keyword) }
    end

    def keyword_pattern(keyword)
      escaped = keyword.to_s.split(/\s+/).map { |term| Regexp.escape(term) }.join("\\s+")
      /\b#{escaped}\b/i
    end

    def notify_analysis_failure(article, analysis)
      error = analysis[:error] || analysis["error"]
      return if error.blank?

      symbols = article.symbols
      symbols_str = symbols.any? ? symbols.first(3).join(", ") : "General"
      headline = ActionView::Base.full_sanitizer.sanitize(article.headline.to_s).gsub(/\s+/, " ").strip
      short_error = error.to_s.strip
      short_error = "#{short_error[0, 160]}..." if short_error.length > 160

      message = "News analysis failed for #{symbols_str}: #{headline}. Error: #{short_error}"
      DiscordService.post_to_infra(content: message)
    rescue StandardError => e
      Rails.logger.warn("Failed to notify infra about analysis failure: #{e.message}")
    end
  end
end
