module Api
  module V1
    class NewsController < ApplicationController
      trail_tool :latest, scope: :agent, name: "get_news_latest",
        description: "Get the latest desk news summary."
      trail_tool :ticker, scope: :agent, name: "get_ticker_news",
        description: "Get recent news for a specific ticker.",
        query: {
          ticker: { type: "string", description: "Ticker symbol", required: true },
          days: { type: "integer", description: "Lookback window in days (default 7)" },
          limit: { type: "integer", description: "Max articles (default 30)" }
        }

      # GET /api/v1/news
      def index
        articles = NewsArticle.includes(:news_symbols).recent_first
        articles = filter_by_symbols(articles)
        articles = filter_by_since(articles)

        limit = params[:limit].to_i
        limit = 100 if limit <= 0
        limit = 500 if limit > 500
        articles = articles.limit(limit)

        render json: articles.map { |article| article_json(article) }
      end

      # GET /api/v1/news/ticker?symbol=NVDA&days=7&limit=30
      def ticker
        symbol = params[:symbol].presence || params[:ticker].presence
        return render json: { error: 'symbol is required' }, status: :bad_request unless symbol

        symbol = symbol.to_s.strip.upcase
        days = (params[:days] || 7).to_i
        days = 1 if days <= 0
        limit = params[:limit].to_i
        limit = 30 if limit <= 0
        limit = 200 if limit > 200

        cutoff = days.days.ago

        articles = NewsArticle.joins(:news_symbols)
                              .includes(:news_symbols)
                              .where(news_symbols: { symbol: symbol })
                              .where('published_at >= ?', cutoff)
                              .order(published_at: :desc)
                              .limit(limit)

        render json: {
          symbol: symbol,
          since: cutoff,
          count: articles.size,
          articles: articles.map { |article| article_json(article) }
        }
      end

      # GET /api/v1/news/:id
      def show
        article = NewsArticle.includes(:news_symbols).find(params[:id])
        render json: article_json(article)
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'News article not found' }, status: :not_found
      end

      # GET /api/v1/news/latest
      def latest
        summary = NewsSummary.where(summary_type: 'latest_60m').order(created_at: :desc).first
        if summary
          render json: { summary_type: summary.summary_type, body: summary.body, created_at: summary.created_at }
        else
          render json: { summary_type: 'latest_60m', body: '*No recent news articles.*', created_at: nil }
        end
      end

      private

      def filter_by_symbols(scope)
        return scope unless params[:symbols].present?
        symbols = params[:symbols].to_s.split(',').map { |s| s.strip.upcase }.reject(&:blank?)
        return scope if symbols.empty?

        scope.joins(:news_symbols).where(news_symbols: { symbol: symbols }).distinct
      end

      def filter_by_since(scope)
        return scope unless params[:since].present?
        since = Time.zone.parse(params[:since])
        scope.where('published_at >= ?', since)
      rescue ArgumentError, TypeError
        scope
      end

      def article_json(article)
        {
          id: article.id,
          external_id: article.external_id,
          headline: article.headline,
          source: article.source,
          summary: article.summary,
          content: article.content,
          url: article.url,
          symbols: article.symbols,
          published_at: article.published_at,
          fetched_at: article.fetched_at,
          file_path: article.file_path
        }
      end
    end
  end
end
