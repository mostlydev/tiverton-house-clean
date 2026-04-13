# frozen_string_literal: true

# Outbox pattern for exactly-once notification delivery
# All notifications must go through the outbox; direct notification calls are removed
class CreateOutbox < ActiveRecord::Migration[7.2]
  def change
    create_table :outbox_events do |t|
      # Dedupe key: event_type + aggregate_type + aggregate_id + sequence_key
      t.string :event_type, null: false
      t.string :aggregate_type, null: false  # Trade, BrokerFill, etc.
      t.bigint :aggregate_id, null: false
      t.string :sequence_key  # broker_fill_id or event sequence

      # Payload
      t.jsonb :payload, default: {}

      # Processing state
      t.string :status, default: 'pending'  # pending, processing, completed, failed, dead_letter
      t.integer :attempts, default: 0
      t.datetime :scheduled_at, null: false
      t.datetime :processed_at
      t.datetime :last_attempt_at
      t.text :last_error

      # Locking
      t.string :locked_by
      t.datetime :locked_at

      t.timestamps
    end

    # Dedupe index - prevents duplicate events
    add_index :outbox_events,
              [:event_type, :aggregate_type, :aggregate_id, :sequence_key],
              unique: true,
              name: 'idx_outbox_events_dedupe'

    # Processing index - for finding events to process
    add_index :outbox_events, [:status, :scheduled_at], name: 'idx_outbox_events_pending'

    # Dead letter query
    add_index :outbox_events, :status, where: "status = 'dead_letter'", name: 'idx_outbox_events_dead_letter'
  end
end
