class CreateAgents < ActiveRecord::Migration[7.2]
  def change
    create_table :agents do |t|
      t.string :agent_id, null: false
      t.string :name, null: false
      t.string :role, null: false
      t.string :style
      t.string :status, null: false, default: 'active'

      t.timestamps
    end

    add_index :agents, :agent_id, unique: true

    # Add check constraints
    execute <<-SQL
      ALTER TABLE agents
      ADD CONSTRAINT check_agent_role
      CHECK (role IN ('trader', 'infrastructure'));

      ALTER TABLE agents
      ADD CONSTRAINT check_agent_status
      CHECK (status IN ('active', 'paused', 'disabled'));
    SQL
  end
end
