class Trade < ApplicationRecord
  include AASM

  # Associations
  belongs_to :agent
  has_many :trade_events, dependent: :destroy

  # Validations
  validates :trade_id, presence: true, uniqueness: true
  validates :ticker, presence: true
  validates :side, presence: true, inclusion: { in: %w[BUY SELL] }
  validates :order_type, presence: true, inclusion: { in: %w[MARKET LIMIT STOP STOP_LIMIT TRAILING_STOP] }
  validates :asset_class, presence: true, inclusion: { in: %w[us_equity us_option crypto crypto_perp] }
  validates :execution_policy, presence: true, inclusion: { in: %w[immediate allow_extended queue_until_open] }
  validates :status, presence: true
  validate :qty_or_amount_present
  validate :filled_requires_alpaca_order_id
  validates :is_urgent, inclusion: { in: [ true, false ] }
  validates :extended_hours, inclusion: { in: [ true, false ] }

  # Callbacks
  before_validation :generate_trade_id, on: :create
  after_commit :notify_proposed, on: :create
  after_update :log_status_change, if: :saved_change_to_status?
  after_update :notify_confirmed, if: :saved_change_to_confirmed_at?

  # Scopes
  scope :proposed, -> { where(status: "PROPOSED") }
  scope :pending, -> { where(status: "PENDING") }
  scope :approved, -> { where(status: "APPROVED") }
  scope :queued, -> { where(status: "QUEUED") }
  scope :executing, -> { where(status: "EXECUTING") }
  scope :filled, -> { where(status: "FILLED") }
  scope :denied, -> { where(status: "DENIED") }
  scope :urgent, -> { where(is_urgent: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :stop_loss_auto, -> { where("thesis LIKE ?", "%STOP_LOSS_AUTO%") }

  # AASM State Machine
  aasm column: :status do
    state :PROPOSED, initial: true
    state :PENDING
    state :APPROVED
    state :QUEUED
    state :DENIED
    state :EXECUTING
    state :FILLED
    state :PARTIALLY_FILLED
    state :CANCELLED
    state :FAILED
    state :PASSED

    # PROPOSED transitions
    event :approve do
      transitions from: :PROPOSED, to: :APPROVED, after: :set_approved_timestamp
      after_commit :notify_approved
      after_commit :enqueue_auto_execute
    end

    event :deny do
      transitions from: :PROPOSED, to: :DENIED, after: :set_denied_timestamp
      after_commit :notify_denied
    end

    event :pass do
      transitions from: :PROPOSED, to: :PASSED
      after_commit :notify_passed
    end

    event :cancel_from_proposed do
      transitions from: :PROPOSED, to: :CANCELLED
      after_commit :notify_cancelled
    end

    # PENDING transitions (legacy)
    event :approve_from_pending do
      transitions from: :PENDING, to: :APPROVED, after: :set_approved_timestamp
      after_commit :notify_approved
      after_commit :enqueue_auto_execute
    end

    event :deny_from_pending do
      transitions from: :PENDING, to: :DENIED, after: :set_denied_timestamp
      after_commit :notify_denied
    end

    event :cancel_from_pending do
      transitions from: :PENDING, to: :CANCELLED
      after_commit :notify_cancelled
    end

    # APPROVED transitions
    event :execute do
      transitions from: :APPROVED, to: :EXECUTING, after: :set_execution_started_timestamp
    end

    event :queue do
      transitions from: :APPROVED, to: :QUEUED, after: :set_queued_timestamp
    end

    event :release do
      transitions from: :QUEUED, to: :APPROVED
    end

    event :cancel_from_approved do
      transitions from: :APPROVED, to: :CANCELLED
      after_commit :notify_cancelled
    end

    # EXECUTING transitions
    event :fill do
      transitions from: :EXECUTING, to: :FILLED, after: :set_filled_timestamp
      after_commit :notify_filled
    end

    event :partial_fill do
      transitions from: :EXECUTING, to: :PARTIALLY_FILLED
      after_commit :notify_partial
    end

    event :fail do
      transitions from: [ :APPROVED, :QUEUED, :EXECUTING ], to: :FAILED
      after_commit :notify_failed
    end

    event :cancel_from_executing do
      transitions from: :EXECUTING, to: :CANCELLED
      after_commit :notify_cancelled
    end

    # PARTIALLY_FILLED transitions
    event :complete_fill do
      transitions from: :PARTIALLY_FILLED, to: :FILLED, after: :set_filled_timestamp
      after_commit :notify_filled
    end

    event :cancel_from_partial do
      transitions from: :PARTIALLY_FILLED, to: :CANCELLED
      after_commit :notify_cancelled
    end

    # General cancel event (convenience method)
    event :cancel do
      transitions from: [ :PROPOSED, :PENDING, :APPROVED, :QUEUED, :EXECUTING ], to: :CANCELLED
      after_commit :notify_cancelled
    end
  end

  trail id: :trade_id do
    # confirm is a field mutation (sets confirmed_at), not an AASM transition
    from :PROPOSED, can: [:confirm], if: -> { confirmed_at.blank? },
         description: "Confirm you want to proceed after advisory feedback"

    # Only surface the primary AASM events (hides cancel_from_proposed, etc.)
    expose :approve, :deny, :pass, :cancel, :execute, :fill, :fail, :queue, :release
  end

  # Instance methods
  def terminal_state?
    %w[FILLED DENIED CANCELLED FAILED PASSED].include?(status)
  end

  def can_execute?
    APPROVED? && confirmed_at.present?
  end

  def notional_value
    return nil unless amount_requested
    amount_requested
  end

  def quantity_value
    return nil unless qty_requested
    qty_requested
  end

  def to_s
    "Trade #{trade_id}: #{side} #{qty_requested || amount_requested} #{ticker} (#{status})"
  end

  def stop_loss_exit?
    return false unless side == "SELL"

    return true if %w[STOP STOP_LIMIT].include?(order_type)

    thesis_text = thesis.to_s.upcase
    thesis_text.include?("STOP LOSS") || thesis_text.include?("STOP_LOSS") || thesis_text.include?("STOP-LOSS")
  end

  private

  def confirmed_for_approval?
    confirmed_at.present?
  end

  def generate_trade_id
    self.trade_id ||= "#{agent.agent_id}-#{Time.current.to_i}-#{SecureRandom.hex(4)}"
  end

  def set_approved_timestamp
    self.approved_at = Time.current
  end

  def set_denied_timestamp
    # denied_at field doesn't exist, but we track this in updated_at
  end

  def set_execution_started_timestamp
    self.execution_started_at = Time.current
  end

  def set_queued_timestamp
    self.queued_at = Time.current
  end

  def set_filled_timestamp
    self.execution_completed_at = Time.current
  end

  def log_status_change
    trade_events.create!(
      event_type: status,
      actor: approved_by || executed_by || "system",
      details: {
        old_status: status_before_last_save,
        new_status: status,
        approved_by: approved_by,
        executed_by: executed_by,
        qty_filled: qty_filled,
        avg_fill_price: avg_fill_price,
        is_urgent: is_urgent
      }
    )
  end

  def qty_or_amount_present
    if qty_requested.blank? && amount_requested.blank?
      errors.add(:base, "Either qty_requested or amount_requested must be present")
    end
  end

  def filled_requires_alpaca_order_id
    if %w[FILLED PARTIALLY_FILLED].include?(status) && alpaca_order_id.blank?
      errors.add(:alpaca_order_id, "is required when status is #{status}")
    end
  end

  # Notification callbacks (after_commit hooks) — routed through outbox for dedup
  def notify_approved
    OutboxPublisherService.trade_approved!(self)
  end

  def notify_denied
    OutboxPublisherService.trade_denied!(self)
  end

  def notify_passed
    OutboxPublisherService.trade_passed!(self)
  end

  def notify_filled
    OutboxPublisherService.trade_filled!(self)
  end

  def notify_partial
    OutboxPublisherService.trade_partial_fill!(self)
  end

  def notify_failed
    OutboxPublisherService.trade_failed!(self)
  end

  def notify_cancelled
    return if denial_reason == "STALE_PROPOSAL"
    OutboxPublisherService.trade_canceled!(self)
  end

  def notify_proposed
    OutboxPublisherService.trade_proposed!(self)
  end

  def notify_confirmed
    return unless confirmed_at.present?
    OutboxPublisherService.trade_confirmed!(self)
  end

  def enqueue_auto_execute
    Trades::ExecutionSchedulerService.new(self).call
  end
end
