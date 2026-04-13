# frozen_string_literal: true

module News
  class LatestSummaryService
    WINDOW_MINUTES = AppConfig.news_summary_window_minutes

    def call
      cutoff = WINDOW_MINUTES.minutes.ago
      articles = NewsArticle.where("published_at > ?", cutoff).recent_first

      updated_at = Time.current.utc.strftime("%Y-%m-%d %H:%M UTC")
      body = +"# News Summary (last #{WINDOW_MINUTES} min)\n"
      body << "Updated: #{updated_at}\n\n"

      if articles.empty?
        body << "*No recent news articles.*\n"
      else
        articles.each do |article|
          symbols = article.symbols
          symbols_str = symbols.any? ? symbols.first(3).join(", ") : "General"
          time_str = article.published_at&.strftime("%H:%M")
          body << "- **#{symbols_str}**: #{article.headline} [#{article.source} #{time_str}]\n"
        end
      end

      NewsSummary.create!(summary_type: "latest_60m", body: body, metadata: { cutoff: cutoff })
      body
    end
  end
end
