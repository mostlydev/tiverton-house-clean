class AddDiscordUrlToTrades < ActiveRecord::Migration[7.0]
  def change
    add_column :trades, :discord_url, :string
    add_index :trades, :discord_url
  end
end
