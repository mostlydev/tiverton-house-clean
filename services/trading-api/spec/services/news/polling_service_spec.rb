# frozen_string_literal: true

require 'rails_helper'

RSpec.describe News::PollingService do
  describe 'macro keyword gating' do
    it 'uses word boundaries to avoid false macro matches' do
      service = described_class.new

      expect(service.send(:macro_hit?, 'Stock rises on upward momentum', 'No macro catalysts')).to be(false)
      expect(service.send(:macro_hit?, 'Fed signals rate cut path', 'Markets reprice treasury yields')).to be(true)
    end

    it 'routes macro news to dundas instead of gerrard' do
      service = described_class.new
      article = create(:news_article, headline: 'Fed rate cut surprise', content: 'Policy statement details')

      analysis = {
        success: true,
        impact: 'HIGH',
        route_to: [ 'gerrard' ],
        auto_post: true,
        reasoning: 'Macro event'
      }

      gated = service.send(:apply_gating, article, analysis, {}, {})

      expect(gated[:route_to]).to eq([ 'dundas' ])
    end
  end

  describe 'analysis prefiltering' do
    let(:service) { described_class.new }

    it 'skips AI analysis for broad multi-symbol market-mover roundups' do
      article = create(:news_article,
        headline: "12 Health Care Stocks Moving In Thursday's Pre-Market Session",
        content: "A broad pre-market movers roundup."
      )
      %w[ADVB AIFF ARTL CBUS ENTA EUDA ICCM KOD PGEN RANI RMTI WVE].each do |symbol|
        create(:news_symbol, news_article: article, symbol: symbol)
      end

      expect(News::AnalysisService).not_to receive(:new)

      analysis = service.send(:preclassified_analysis, article)

      expect(analysis).to include(
        success: true,
        impact: 'LOW',
        route_to: [],
        auto_post: false
      )
      expect(analysis[:reasoning]).to include('Skipped AI analysis')
    end

    it 'does not skip materially relevant macro headlines with several symbols' do
      article = create(:news_article,
        headline: 'Dow Falls 250 Points; US Initial Jobless Claims Rise',
        content: 'Macro data moved markets this morning.'
      )
      %w[APP KOD NAVN NEXT PONY VICR].each do |symbol|
        create(:news_symbol, news_article: article, symbol: symbol)
      end

      expect(service.send(:preclassified_analysis, article)).to be_nil
    end
  end
end
