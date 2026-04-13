# frozen_string_literal: true

# Records provenance metadata for reconciliation runs.
# Used to track emergency/bootstrap reconciliation events and link them to ledger adjustments.
#
# Per migration plan v5, any ownership/cash reassignment from emergency logic must link to this record.
class ReconciliationProvenance < ApplicationRecord
  validates :run_id, presence: true, uniqueness: true
  validates :runner_script, presence: true
  validates :started_at, presence: true

  # Serialize report_paths as JSON array
  serialize :report_paths, coder: JSON

  scope :completed, -> { where(status: 'completed') }
  scope :bootstrap, -> { where(assignment_strategy: 'bootstrap') }

  # Create a provenance record from a reconciliation artifact file
  def self.create_from_artifact!(artifact_path, run_id:, operator: 'system', notes: nil)
    artifact = JSON.parse(File.read(artifact_path))

    create!(
      run_id: run_id,
      runner_script: 'script/full_reconcile_alpaca.rb',
      runner_version: '1.0',
      invocation_params: {
        artifact_source: artifact_path
      },
      assignment_strategy: 'bootstrap',
      input_checksum: Digest::SHA256.hexdigest(File.read(artifact_path)),
      output_checksum: Digest::SHA256.hexdigest(artifact.to_json),
      operator: operator,
      started_at: Time.parse(artifact['generated_at']),
      completed_at: Time.parse(artifact['generated_at']),
      report_paths: [artifact_path],
      notes: notes,
      status: 'completed'
    )
  end
end
