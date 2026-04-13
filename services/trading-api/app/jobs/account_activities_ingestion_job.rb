# frozen_string_literal: true

# Polls Alpaca Activities API for fills, dividends, fees, and other account activities.
# Ingests into broker_fills and broker_account_activities tables with idempotency.
# Schedule: every 1-5 minutes during market hours, 15-30 off-hours.
class AccountActivitiesIngestionJob < ApplicationJob
  queue_as :default

  # Activity types we care about
  FILL_TYPES = %w[FILL].freeze
  ACCOUNT_ACTIVITY_TYPES = %w[DIV DIVNRA FEE INT CSD CSW ACATC ACATS REORG SPIN MA].freeze

  # Redis key for last poll timestamp (fallback to 24h ago if not set)
  LAST_POLL_KEY = 'alpaca_activities_last_poll'
  DEFAULT_LOOKBACK = 24.hours

  def perform
    Rails.logger.info('[ActivitiesIngestion] Starting activities poll')

    # Get last poll time
    since = last_poll_time
    if Broker::Cutover.configured?
      Rails.logger.info("[ActivitiesIngestion] Broker cutover active at #{Broker::Cutover.configured_at.iso8601}")
    end
    Rails.logger.info("[ActivitiesIngestion] Polling activities since #{since.iso8601}")

    # Fetch all relevant activity types
    all_activities = fetch_all_activities(since: since)

    if all_activities.empty?
      Rails.logger.info('[ActivitiesIngestion] No new activities found')
      record_poll_time
      return
    end

    Rails.logger.info("[ActivitiesIngestion] Found #{all_activities.size} activities to process")

    # Separate fills from other activities
    fills, account_activities = all_activities.partition { |a| FILL_TYPES.include?(a[:activity_type]) }

    # Process fills
    fill_stats = process_fills(fills)
    Rails.logger.info("[ActivitiesIngestion] Fills: #{fill_stats[:created]} created, #{fill_stats[:skipped]} skipped (duplicates)")

    # Process account activities
    activity_stats = process_account_activities(account_activities)
    Rails.logger.info("[ActivitiesIngestion] Activities: #{activity_stats[:created]} created, #{activity_stats[:skipped]} skipped")

    # Record successful poll
    record_poll_time

    Rails.logger.info('[ActivitiesIngestion] Activities poll complete')
  end

  private

  def fetch_all_activities(since:)
    broker = Alpaca::BrokerService.new
    all_activities = []
    page_token = nil

    # Fetch fills
    loop do
      result = broker.get_activities(
        activity_types: FILL_TYPES,
        since: since,
        page_token: page_token
      )

      unless result[:success]
        Rails.logger.warn("[ActivitiesIngestion] Failed to fetch fills: #{result[:error]}")
        break
      end

      all_activities.concat(result[:activities])
      page_token = result[:next_page_token]
      break if page_token.blank?
    end

    # Fetch account activities
    page_token = nil
    loop do
      result = broker.get_activities(
        activity_types: ACCOUNT_ACTIVITY_TYPES,
        since: since,
        page_token: page_token
      )

      unless result[:success]
        Rails.logger.warn("[ActivitiesIngestion] Failed to fetch account activities: #{result[:error]}")
        break
      end

      all_activities.concat(result[:activities])
      page_token = result[:next_page_token]
      break if page_token.blank?
    end

    apply_cutover(all_activities)
  end

  def process_fills(fills)
    stats = { created: 0, skipped: 0 }
    ingestion_service = Broker::FillIngestionService.new

    fills.each do |fill|
      next if fill[:id].blank?

      # Try to find the associated broker_order and trade
      broker_order = find_broker_order(fill[:order_id])
      trade = broker_order&.trade || Trade.find_by(alpaca_order_id: fill[:order_id])

      result = ingestion_service.ingest!(
        broker_fill_id: fill[:id],
        broker_order_id: fill[:order_id],
        trade: trade,
        ticker: fill[:symbol],
        side: fill[:side],
        qty: fill[:qty],
        price: fill[:price],
        executed_at: parse_time(fill[:transaction_time]),
        fill_id_confidence: 'broker_verified',
        raw_fill: fill
      )

      if result.success
        # Check if it was a new fill or existing
        if result.fill&.created_at && result.fill.created_at > 5.seconds.ago
          stats[:created] += 1
          Rails.logger.debug("[ActivitiesIngestion] Created fill: #{fill[:id]} for #{fill[:symbol]}")
        else
          stats[:skipped] += 1
        end
      else
        Rails.logger.error("[ActivitiesIngestion] Error processing fill #{fill[:id]}: #{result.errors.join(', ')}")
      end
    end

    stats
  end

  def process_account_activities(activities)
    stats = { created: 0, skipped: 0 }

    activities.each do |activity|
      next if activity[:id].blank?

      # Check for existing activity by broker_activity_id
      if BrokerAccountActivity.exists?(broker_activity_id: activity[:id])
        stats[:skipped] += 1
        next
      end

      # Create the activity record
      BrokerAccountActivity.create!(
        broker_activity_id: activity[:id],
        activity_type: activity[:activity_type],
        ticker: activity[:symbol],
        qty: activity[:qty],
        price: activity[:price],
        net_amount: activity[:net_amount],
        description: activity[:description],
        activity_date: parse_time(activity[:transaction_time]),
        raw_activity: activity.to_json
      )

      stats[:created] += 1
      Rails.logger.debug("[ActivitiesIngestion] Created activity: #{activity[:id]} (#{activity[:activity_type]})")

    rescue ActiveRecord::RecordNotUnique
      stats[:skipped] += 1
    rescue StandardError => e
      Rails.logger.error("[ActivitiesIngestion] Error processing activity #{activity[:id]}: #{e.message}")
    end

    stats
  end

  def find_broker_order(order_id)
    return nil if order_id.blank?
    BrokerOrder.find_by(broker_order_id: order_id)
  end

  def last_poll_time
    cached = Rails.cache.read(LAST_POLL_KEY)
    return Broker::Cutover.apply(Time.parse(cached)) if cached.present?

    # Default to 24h ago for first run
    Broker::Cutover.apply(DEFAULT_LOOKBACK.ago)
  end

  def record_poll_time
    Rails.cache.write(LAST_POLL_KEY, Time.current.iso8601, expires_in: 7.days)
  end

  def apply_cutover(activities)
    return activities unless Broker::Cutover.configured?

    filtered = activities.select do |activity|
      Broker::Cutover.allow?(parse_time(activity[:transaction_time]))
    end

    skipped = activities.size - filtered.size
    Rails.logger.info("[ActivitiesIngestion] Skipped #{skipped} pre-cutover activities") if skipped.positive?
    filtered
  end

  def parse_time(time_string)
    return nil if time_string.blank?
    Time.parse(time_string)
  rescue StandardError
    nil
  end
end
