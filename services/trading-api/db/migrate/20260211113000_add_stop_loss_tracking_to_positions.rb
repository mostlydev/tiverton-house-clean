# frozen_string_literal: true

class AddStopLossTrackingToPositions < ActiveRecord::Migration[7.2]
  class MigrationPosition < ApplicationRecord
    self.table_name = 'positions'
  end

  class MigrationTrade < ApplicationRecord
    self.table_name = 'trades'
  end

  def up
    add_column :positions, :stop_loss, :decimal, precision: 15, scale: 4
    add_column :positions, :target_price, :decimal, precision: 15, scale: 4
    add_column :positions, :stop_loss_source_trade_id, :bigint
    add_column :positions, :stop_loss_triggered_at, :datetime
    add_column :positions, :stop_loss_last_alert_at, :datetime
    add_column :positions, :stop_loss_alert_count, :integer, null: false, default: 0

    add_index :positions, :stop_loss_source_trade_id
    add_index :positions, [:agent_id, :stop_loss], where: "qty != 0", name: "idx_positions_open_stop_loss"

    execute <<~SQL
      ALTER TABLE positions
      ADD CONSTRAINT check_position_stop_loss_positive
      CHECK (stop_loss IS NULL OR stop_loss > 0);
    SQL

    execute <<~SQL
      ALTER TABLE positions
      ADD CONSTRAINT check_position_target_price_positive
      CHECK (target_price IS NULL OR target_price > 0);
    SQL

    backfill_stop_losses!

    execute <<~SQL
      ALTER TABLE positions
      ADD CONSTRAINT check_open_positions_have_stop_loss
      CHECK (qty = 0 OR stop_loss IS NOT NULL);
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE positions
      DROP CONSTRAINT IF EXISTS check_open_positions_have_stop_loss;
    SQL

    execute <<~SQL
      ALTER TABLE positions
      DROP CONSTRAINT IF EXISTS check_position_stop_loss_positive;
    SQL

    execute <<~SQL
      ALTER TABLE positions
      DROP CONSTRAINT IF EXISTS check_position_target_price_positive;
    SQL

    remove_index :positions, name: "idx_positions_open_stop_loss"
    remove_index :positions, :stop_loss_source_trade_id

    remove_column :positions, :stop_loss_alert_count
    remove_column :positions, :stop_loss_last_alert_at
    remove_column :positions, :stop_loss_triggered_at
    remove_column :positions, :stop_loss_source_trade_id
    remove_column :positions, :target_price
    remove_column :positions, :stop_loss
  end

  private

  def backfill_stop_losses!
    say_with_time 'Backfilling position stop_loss from latest filled BUY trades' do
      MigrationPosition.where('qty != 0').find_each do |position|
        next if position.stop_loss.present?

        source_trade = MigrationTrade
          .where(agent_id: position.agent_id, ticker: position.ticker, side: 'BUY', status: 'FILLED')
          .where.not(stop_loss: nil)
          .order(execution_completed_at: :desc, created_at: :desc)
          .first

        stop_loss = source_trade&.stop_loss
        if stop_loss.blank?
          direction = position.qty.to_f.negative? ? 1.0 : -1.0
          fallback = position.avg_entry_price.to_f * (1.0 + (direction * AppConfig.stop_loss_fallback_percent))
          stop_loss = fallback.positive? ? fallback.round(4) : nil
        end

        position.update_columns(
          stop_loss: stop_loss,
          target_price: source_trade&.target_price,
          stop_loss_source_trade_id: source_trade&.id,
          updated_at: Time.current
        )
      end
    end
  end
end
