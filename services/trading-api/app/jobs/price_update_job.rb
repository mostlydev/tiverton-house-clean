# frozen_string_literal: true

class PriceUpdateJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform
    PriceUpdateService.new.call
  end
end
