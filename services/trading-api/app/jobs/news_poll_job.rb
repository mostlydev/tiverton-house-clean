# frozen_string_literal: true

class NewsPollJob < ApplicationJob
  queue_as :default

  # Exponential backoff: 3s, 18s, 83s
  retry_on StandardError, wait: ->(executions) { executions ** 4 }, attempts: 3

  def perform
    News::PollingService.new.call
  end
end
