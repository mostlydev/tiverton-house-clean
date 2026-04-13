# frozen_string_literal: true

class BrokerAccountSnapshotJob < ApplicationJob
  queue_as :default

  def perform
    result = BrokerAccountSnapshotService.new.call
    if result[:success]
      Rails.logger.info("BrokerAccountSnapshotJob: stored snapshot at #{result[:snapshot].fetched_at}")
      sync_result = Wallets::BrokerFundingSyncService.new(snapshot: result[:snapshot]).call

      if sync_result[:success] && sync_result[:applied]
        Rails.logger.info(
          "BrokerAccountSnapshotJob: synced funded trader wallets " \
          "(#{sync_result[:funded_trader_ids].join(', ')}) from broker snapshot"
        )
      elsif sync_result[:success] && sync_result[:skipped]
        Rails.logger.info("BrokerAccountSnapshotJob: skipped wallet sync - #{sync_result[:reason]}")
      else
        Rails.logger.warn("BrokerAccountSnapshotJob: wallet sync failed - #{sync_result[:error]}")
      end
    else
      Rails.logger.warn("BrokerAccountSnapshotJob: failed - #{result[:error]}")
    end
  rescue StandardError => e
    Rails.logger.error("BrokerAccountSnapshotJob: error - #{e.class} #{e.message}")
  end
end
