class AddAnalystRoleToAgents < ActiveRecord::Migration[7.2]
  def up
    execute <<-SQL
      ALTER TABLE agents DROP CONSTRAINT check_agent_role;
      ALTER TABLE agents
      ADD CONSTRAINT check_agent_role
      CHECK (role IN ('trader', 'infrastructure', 'analyst'));
    SQL
  end

  def down
    execute <<-SQL
      ALTER TABLE agents DROP CONSTRAINT check_agent_role;
      ALTER TABLE agents
      ADD CONSTRAINT check_agent_role
      CHECK (role IN ('trader', 'infrastructure'));
    SQL
  end
end
