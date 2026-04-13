class InvestigationEntity < ApplicationRecord
  ROLES = %w[target supplier customer competitor key_person regulator adjacent].freeze

  belongs_to :investigation
  belongs_to :research_entity

  validates :role, presence: true, inclusion: { in: ROLES }
  validates :research_entity_id, uniqueness: { scope: :investigation_id }
end
