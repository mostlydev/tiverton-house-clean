# frozen_string_literal: true

module News
  class IngestionService
    attr_reader :created_articles

    def initialize(raw_articles, fetched_at: Time.current)
      @raw_articles = raw_articles || []
      @fetched_at = fetched_at
      @created_articles = []
    end

    def call
      ActiveRecord::Base.transaction do
        @raw_articles.each do |article|
          external_id = article['id'].to_s
          next if external_id.blank?

          published_at = parse_time(article['created_at'] || article['published_at']) || @fetched_at

          # Use find_or_create_by to handle race conditions
          news_article = NewsArticle.find_or_create_by!(external_id: external_id) do |na|
            na.headline = article['headline']
            na.source = article['source']
            na.content = article['content']
            na.summary = article['summary']
            na.url = article['url']
            na.published_at = published_at
            na.fetched_at = @fetched_at
            na.raw_json = article
          end

          # Skip symbol processing if article already existed
          next unless news_article.previously_new_record?

          symbols_value = article['symbols'] || article['symbol'] || []
          symbols_value = [symbols_value] unless symbols_value.is_a?(Array)
          symbols = symbols_value.map { |s| s.to_s.upcase }
          symbols.uniq.each do |symbol|
            next if symbol.blank?
            news_article.news_symbols.create!(symbol: symbol)
          end

          @created_articles << news_article
        end
      end

      @created_articles
    end

    private

    def parse_time(value)
      return nil if value.blank?
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
