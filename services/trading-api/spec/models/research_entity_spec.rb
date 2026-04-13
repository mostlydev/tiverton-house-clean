require 'rails_helper'

RSpec.describe ResearchEntity, type: :model do
  describe 'validations' do
    it 'is valid with valid attributes' do
      entity = build(:research_entity)
      expect(entity).to be_valid
    end

    it 'is invalid without a name' do
      entity = build(:research_entity, name: nil)
      expect(entity).not_to be_valid
      expect(entity.errors[:name]).to include("can't be blank")
    end

    it 'is invalid without an entity_type' do
      entity = build(:research_entity, entity_type: nil)
      expect(entity).not_to be_valid
      expect(entity.errors[:entity_type]).to include("can't be blank")
    end

    it 'rejects invalid entity types' do
      entity = build(:research_entity, entity_type: 'spaceship')
      expect(entity).not_to be_valid
      expect(entity.errors[:entity_type]).to include("is not included in the list")
    end

    it 'accepts all valid entity types' do
      %w[company person sector theme regulator].each do |et|
        entity = build(:research_entity, entity_type: et)
        expect(entity).to be_valid, "expected entity_type '#{et}' to be valid"
      end
    end
  end

  describe 'associations' do
    it 'has outgoing relationships' do
      entity = create(:research_entity)
      target = create(:research_entity, name: 'Google', ticker: 'GOOGL')
      rel = create(:research_relationship, source_entity: entity, target_entity: target)

      expect(entity.outgoing_relationships).to include(rel)
    end

    it 'has incoming relationships' do
      entity = create(:research_entity)
      source = create(:research_entity, name: 'Google', ticker: 'GOOGL')
      rel = create(:research_relationship, source_entity: source, target_entity: entity)

      expect(entity.incoming_relationships).to include(rel)
    end

    it 'returns related entities from both directions' do
      entity = create(:research_entity)
      partner = create(:research_entity, name: 'Google', ticker: 'GOOGL')
      supplier = create(:research_entity, name: 'TSMC', ticker: 'TSM')

      create(:research_relationship, source_entity: entity, target_entity: partner, relationship_type: 'partners_with')
      create(:research_relationship, source_entity: supplier, target_entity: entity, relationship_type: 'supplies')

      related = entity.related_entities
      expect(related).to include(partner, supplier)
      expect(related).not_to include(entity)
    end
  end

  describe 'scopes' do
    it '.companies returns only company entities' do
      company = create(:research_entity, entity_type: 'company')
      create(:research_entity, :person)

      expect(described_class.companies).to contain_exactly(company)
    end

    it '.people returns only person entities' do
      create(:research_entity, entity_type: 'company')
      person = create(:research_entity, :person)

      expect(described_class.people).to contain_exactly(person)
    end

    it '.by_ticker finds by ticker symbol' do
      aapl = create(:research_entity, ticker: 'AAPL')
      create(:research_entity, name: 'Google', ticker: 'GOOGL')

      expect(described_class.by_ticker('AAPL')).to contain_exactly(aapl)
    end
  end
end
