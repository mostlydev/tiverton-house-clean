# frozen_string_literal: true

module Dashboard
  class ResearchService
    def self.for_ticker(ticker)
      new(ticker).content
    end

    def initialize(ticker)
      @ticker = ticker.to_s.upcase
    end

    def content
      return { error: "Invalid ticker" } unless valid_ticker?

      research_path = StoragePaths.research_file_path(@ticker)
      news_path = StoragePaths.research_news_path(@ticker)

      return { error: "No research found for this ticker." } unless research_path.exist?

      content = research_path.read

      # Remove "See: TICKER-news.md" references since we're merging
      content = content.gsub(/See: [A-Z]+-news\.md\n?/, "")

      # Merge news if it exists
      if news_path.exist?
        news_content = news_path.read
        # Skip header lines from news file
        news_body = news_content.lines.reject { |l| l.start_with?("#") || l.start_with?("<!--") }.join

        if content.include?("## Recent News")
          content = content.sub(/## Recent News\s*$/, "## Recent News\n#{news_body.strip}")
        else
          content = "#{content.rstrip}\n\n## Recent News\n#{news_body.strip}"
        end
      end

      { content: content, ticker: @ticker }
    rescue StandardError => e
      { error: e.message }
    end

    private

    def valid_ticker?
      @ticker.match?(/\A[A-Z]{1,5}\z/)
    end
  end
end
