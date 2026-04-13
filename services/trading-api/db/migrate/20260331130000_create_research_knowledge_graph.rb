class CreateResearchKnowledgeGraph < ActiveRecord::Migration[7.2]
  def change
    create_table :research_entities do |t|
      t.string :name, null: false
      t.string :ticker
      t.string :entity_type, null: false
      t.text :summary
      t.jsonb :data, null: false, default: {}
      t.datetime :last_researched_at
      t.timestamps
    end
    add_index :research_entities, :entity_type
    add_index :research_entities, :ticker
    add_index :research_entities, [:entity_type, :name]
    execute <<-SQL
      ALTER TABLE research_entities ADD CONSTRAINT check_research_entity_type
      CHECK (entity_type IN ('company', 'person', 'sector', 'theme', 'regulator'));
    SQL

    create_table :research_relationships do |t|
      t.references :source_entity, null: false, foreign_key: { to_table: :research_entities }
      t.references :target_entity, null: false, foreign_key: { to_table: :research_entities }
      t.string :relationship_type, null: false
      t.text :description
      t.string :strength, null: false, default: 'moderate'
      t.timestamps
    end
    add_index :research_relationships, [:source_entity_id, :target_entity_id, :relationship_type],
              unique: true, name: 'idx_research_rel_unique'
    add_index :research_relationships, :relationship_type
    execute <<-SQL
      ALTER TABLE research_relationships ADD CONSTRAINT check_research_relationship_type
      CHECK (relationship_type IN ('supplies', 'customer_of', 'competes_with', 'managed_by',
        'board_member_of', 'regulates', 'subsidiary_of', 'partners_with', 'invested_in'));
      ALTER TABLE research_relationships ADD CONSTRAINT check_research_relationship_strength
      CHECK (strength IN ('strong', 'moderate', 'weak'));
    SQL

    create_table :investigations do |t|
      t.string :title, null: false
      t.string :status, null: false, default: 'active'
      t.text :thesis
      t.text :recommendation
      t.timestamps
    end
    add_index :investigations, :status
    execute <<-SQL
      ALTER TABLE investigations ADD CONSTRAINT check_investigation_status
      CHECK (status IN ('active', 'paused', 'completed'));
    SQL

    create_table :investigation_entities do |t|
      t.references :investigation, null: false, foreign_key: true
      t.references :research_entity, null: false, foreign_key: true
      t.string :role, null: false
      t.timestamps
    end
    add_index :investigation_entities, [:investigation_id, :research_entity_id], unique: true, name: 'idx_inv_entity_unique'
    execute <<-SQL
      ALTER TABLE investigation_entities ADD CONSTRAINT check_investigation_entity_role
      CHECK (role IN ('target', 'supplier', 'customer', 'competitor', 'key_person', 'regulator', 'adjacent'));
    SQL

    create_table :research_notes do |t|
      t.string :notable_type, null: false
      t.bigint :notable_id, null: false
      t.string :note_type, null: false
      t.text :content, null: false
      t.timestamps
    end
    add_index :research_notes, [:notable_type, :notable_id]
    add_index :research_notes, :note_type
    execute <<-SQL
      ALTER TABLE research_notes ADD CONSTRAINT check_research_note_type
      CHECK (note_type IN ('finding', 'risk_flag', 'thesis_change', 'profit_signal', 'catalyst'));
    SQL
  end
end
