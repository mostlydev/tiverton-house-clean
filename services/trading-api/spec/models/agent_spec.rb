require 'rails_helper'

RSpec.describe Agent, type: :model do
  describe 'validations' do
    it 'is valid with role trader' do
      agent = build(:agent, role: 'trader')
      expect(agent).to be_valid
    end

    it 'is valid with role infrastructure' do
      agent = build(:agent, role: 'infrastructure')
      expect(agent).to be_valid
    end

    it 'is valid with role analyst' do
      agent = build(:agent, role: 'analyst')
      expect(agent).to be_valid
    end

    it 'is invalid with an unknown role' do
      agent = build(:agent, role: 'unknown')
      expect(agent).not_to be_valid
      expect(agent.errors[:role]).to include('is not included in the list')
    end
  end

  describe '#analyst?' do
    it 'returns true when role is analyst' do
      agent = build(:agent, role: 'analyst')
      expect(agent.analyst?).to be true
    end

    it 'returns false when role is trader' do
      agent = build(:agent, role: 'trader')
      expect(agent.analyst?).to be false
    end
  end

  describe '#trader?' do
    it 'returns true when role is trader' do
      agent = build(:agent, role: 'trader')
      expect(agent.trader?).to be true
    end

    it 'returns false when role is analyst' do
      agent = build(:agent, role: 'analyst')
      expect(agent.trader?).to be false
    end
  end

  describe '#infrastructure?' do
    it 'returns true when role is infrastructure' do
      agent = build(:agent, role: 'infrastructure')
      expect(agent.infrastructure?).to be true
    end
  end

  describe 'scopes' do
    it '.analysts returns only analyst agents' do
      analyst = create(:agent, role: 'analyst')
      _trader = create(:agent, role: 'trader')

      expect(Agent.analysts).to contain_exactly(analyst)
    end

    it '.traders returns only trader agents' do
      _analyst = create(:agent, role: 'analyst')
      trader = create(:agent, role: 'trader')

      expect(Agent.traders).to contain_exactly(trader)
    end
  end
end
