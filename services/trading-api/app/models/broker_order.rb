# frozen_string_literal: true

# Immutable record of broker orders submitted to Alpaca.
class BrokerOrder < ApplicationRecord
  belongs_to :trade
  belongs_to :agent

  has_many :broker_order_events, dependent: :destroy
  has_many :broker_fills, dependent: :destroy

  validates :broker_order_id, presence: true, uniqueness: true
  validates :client_order_id, presence: true, uniqueness: true
  validates :ticker, presence: true
  validates :side, presence: true
  validates :order_type, presence: true
  validates :asset_class, presence: true, inclusion: { in: %w[us_equity us_option crypto crypto_perp] }

  scope :pending, -> { where(status: %w[new pending_new accepted]) }
  scope :filled, -> { where(status: 'filled') }
  scope :canceled, -> { where(status: 'canceled') }
end
