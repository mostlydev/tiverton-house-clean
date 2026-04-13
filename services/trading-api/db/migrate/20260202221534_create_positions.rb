class CreatePositions < ActiveRecord::Migration[7.2]
  def change
    create_table :positions do |t|
      t.references :agent, null: false, foreign_key: true
      t.string :ticker, null: false
      t.integer :qty, null: false
      t.decimal :avg_entry_price, precision: 15, scale: 4, null: false
      t.decimal :current_value, precision: 15, scale: 2
      t.datetime :opened_at, null: false, default: -> { 'CURRENT_TIMESTAMP' }

      t.timestamps
    end

    add_index :positions, [:agent_id, :ticker], unique: true
  end
end
