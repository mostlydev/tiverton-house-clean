class ResearchRelationship < ApplicationRecord
  RELATIONSHIP_TYPES = %w[
    supplies customer_of competes_with managed_by board_member_of
    regulates subsidiary_of partners_with invested_in
  ].freeze
  STRENGTHS = %w[strong moderate weak].freeze

  belongs_to :source_entity, class_name: 'ResearchEntity'
  belongs_to :target_entity, class_name: 'ResearchEntity'

  validates :relationship_type, presence: true, inclusion: { in: RELATIONSHIP_TYPES }
  validates :strength, presence: true, inclusion: { in: STRENGTHS }
  validates :source_entity_id, uniqueness: { scope: [:target_entity_id, :relationship_type] }
end
