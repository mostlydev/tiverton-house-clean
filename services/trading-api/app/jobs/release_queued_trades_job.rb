# frozen_string_literal: true

class ReleaseQueuedTradesJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(trade_id = nil)
    scope = Trade.queued
    scope = scope.where(id: trade_id) if trade_id
    scope = scope.where("scheduled_for <= ?", Time.current) unless trade_id

    scope.find_each do |trade|
      Trades::ExecutionSchedulerService.new(trade).call
    end
  end
end
