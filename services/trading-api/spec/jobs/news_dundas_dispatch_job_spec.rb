# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NewsDundasDispatchJob do
  describe '#filter_important_articles' do
    it 'includes only HIGH impact articles that passed auto_post routing gate' do
      job = described_class.new
      a1 = create(:news_article)
      a2 = create(:news_article)
      a3 = create(:news_article)

      analysis = {
        a1.id.to_s => { 'success' => true, 'impact' => 'HIGH', 'auto_post' => true, 'route_to' => ['westin'] },
        a2.id.to_s => { 'success' => true, 'impact' => 'HIGH', 'auto_post' => false, 'route_to' => ['westin'] },
        a3.id.to_s => { 'success' => true, 'impact' => 'HIGH', 'auto_post' => true, 'route_to' => [] }
      }

      result = job.send(:filter_important_articles, [a1, a2, a3], analysis)

      expect(result.map(&:id)).to eq([a1.id])
    end
  end
end
