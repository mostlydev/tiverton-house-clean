class RemoveDiscordUrlFromTrades < ActiveRecord::Migration[7.0]
  def change
    remove_index :trades, :discord_url, if_exists: true
    remove_column :trades, :discord_url, :string
  end
end
