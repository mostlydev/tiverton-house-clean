class CreateWatchlists < ActiveRecord::Migration[7.2]
  def change
    create_table :watchlists do |t|
      t.references :agent, null: false, foreign_key: true
      t.string :ticker, null: false
      t.string :source, null: false, default: 'file'

      t.timestamps
    end

    add_index :watchlists, [:agent_id, :ticker, :source], unique: true, name: 'idx_watchlists_unique'
    add_index :watchlists, :ticker
  end
end
