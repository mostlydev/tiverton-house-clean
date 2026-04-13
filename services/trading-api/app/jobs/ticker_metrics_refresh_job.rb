# frozen_string_literal: true

class TickerMetricsRefreshJob < ApplicationJob
  queue_as :default

  def perform(request)
    result = TickerMetricsRefreshService.run_fetch(request.symbolize_keys)
    Rails.logger.info("TickerMetricsRefreshJob #{request[:fetcher]} #{request[:ticker]}: #{result.inspect}")
  end
end
