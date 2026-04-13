# frozen_string_literal: true

class StaleTradeCheckJob < ApplicationJob
  queue_as :default

  # Retry up to 3 times with exponential backoff
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform
    Trades::StaleTradeService.new.call
  end
end
