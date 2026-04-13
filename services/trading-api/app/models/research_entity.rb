class ResearchEntity < ApplicationRecord
  ENTITY_TYPES = %w[company person sector theme regulator].freeze

  has_many :outgoing_relationships, class_name: 'ResearchRelationship', foreign_key: :source_entity_id, dependent: :destroy
  has_many :incoming_relationships, class_name: 'ResearchRelationship', foreign_key: :target_entity_id, dependent: :destroy
  has_many :investigation_entities, dependent: :destroy
  has_many :investigations, through: :investigation_entities
  has_many :research_notes, as: :notable, dependent: :destroy

  validates :name, presence: true
  validates :entity_type, presence: true, inclusion: { in: ENTITY_TYPES }

  scope :companies, -> { where(entity_type: 'company') }
  scope :people, -> { where(entity_type: 'person') }
  scope :by_ticker, ->(ticker) { where(ticker: ticker) }

  def related_entities
    ids = outgoing_relationships.pluck(:target_entity_id) +
          incoming_relationships.pluck(:source_entity_id)
    ResearchEntity.where(id: ids.uniq).where.not(id: id)
  end
end
