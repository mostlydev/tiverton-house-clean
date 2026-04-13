class CreateTradeEvents < ActiveRecord::Migration[7.2]
  def change
    create_table :trade_events do |t|
      t.references :trade, null: false, foreign_key: true
      t.string :event_type, null: false
      t.string :actor, null: false
      t.jsonb :details, default: {}

      t.timestamps
    end

    add_index :trade_events, :created_at
  end
end
