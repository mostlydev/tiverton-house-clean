# frozen_string_literal: true

module News
  class BatchFormatter
    def initialize(articles, analysis: {})
      @articles = articles
      @analysis = analysis || {}
    end

    def call
      lines = @articles.each_with_index.map do |article, index|
        symbols = article.symbols
        symbols_str = symbols.any? ? symbols.first(3).join(', ') : 'General'
        time_str = article.published_at&.strftime('%H:%M')
        headline = sanitize_headline(article.headline)
        suffix = analysis_suffix(article)
        parts = [symbols_str, time_str, "#{headline}#{suffix}"].compact
        "#{index + 1}. #{parts.join(' | ')}"
      end

      lines.join("\n")
    end

    private

    def sanitize_headline(headline)
      clean = ActionView::Base.full_sanitizer.sanitize(headline.to_s).gsub(/\s+/, ' ').strip
      clean = "#{clean[0, 77]}..." if clean.length > 80
      clean.presence || 'No headline'
    end

    def analysis_suffix(article)
      # No impact labels in output - keep it clean
      ''
    end
  end
end
