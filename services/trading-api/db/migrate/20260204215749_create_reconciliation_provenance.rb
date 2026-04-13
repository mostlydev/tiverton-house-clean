class CreateReconciliationProvenance < ActiveRecord::Migration[7.2]
  def change
    create_table :reconciliation_provenances do |t|
      t.string :run_id, null: false
      t.string :runner_script, null: false
      t.string :runner_version
      t.jsonb :invocation_params, default: {}
      t.string :assignment_strategy
      t.string :input_checksum
      t.string :output_checksum
      t.string :operator
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.text :report_paths
      t.text :notes
      t.string :status, default: 'completed'

      t.timestamps
    end

    add_index :reconciliation_provenances, :run_id, unique: true
    add_index :reconciliation_provenances, [:input_checksum, :output_checksum, :runner_script],
              unique: true,
              name: 'idx_recon_prov_checksums_script'
    add_index :reconciliation_provenances, :started_at
  end
end
