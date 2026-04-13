# frozen_string_literal: true

module News
  class AlpacaClient
    DEFAULT_BASE_URL = 'https://data.alpaca.markets/v1beta1/news'

    def initialize
      @api_key = ENV.fetch('ALPACA_API_KEY')
      @secret_key = ENV.fetch('ALPACA_SECRET_KEY')
      @base_url = ENV.fetch('ALPACA_NEWS_URL', DEFAULT_BASE_URL)
    end

    def fetch(start_time:, end_time:, limit: 50)
      articles = []
      page_token = nil

      loop do
        response = request_page(start_time: start_time, end_time: end_time, limit: limit, page_token: page_token)
        page_articles = extract_articles(response)
        articles.concat(page_articles)

        page_token = response['next_page_token']
        break if page_token.blank?
      end

      articles
    end

    private

    def request_page(start_time:, end_time:, limit:, page_token:)
      params = {
        start: start_time.utc.iso8601,
        end: end_time.utc.iso8601,
        limit: limit.to_i,
        include_content: true
      }
      params[:page_token] = page_token if page_token.present?

      response = Faraday.get(@base_url, params) do |req|
        req.headers['APCA-API-KEY-ID'] = @api_key
        req.headers['APCA-API-SECRET-KEY'] = @secret_key
      end

      unless response.success?
        raise "Alpaca news fetch failed (#{response.status}): #{response.body}"
      end

      JSON.parse(response.body)
    end

    def extract_articles(payload)
      payload['news'] || payload['data'] || []
    end
  end
end
