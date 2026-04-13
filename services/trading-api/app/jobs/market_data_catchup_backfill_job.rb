# frozen_string_literal: true

class MarketDataCatchupBackfillJob < ApplicationJob
  queue_as :low

  CATCHUP_DAYS = 3

  def perform
    MarketDataBackfillService.new(days: CATCHUP_DAYS).call
  end
end
