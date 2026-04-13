# frozen_string_literal: true

require 'rails_helper'

RSpec.describe News::AgentMentions do
  describe '.mention_for' do
    it 'returns a Discord mention for boulton' do
      expect(described_class.mention_for('boulton')).to eq('<@1469917753157750897>')
    end
  end

  describe '.all' do
    it 'includes boulton in the shared mention map' do
      expect(described_class.all).to include('boulton' => '1469917753157750897')
    end
  end
end
