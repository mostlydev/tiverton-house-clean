# frozen_string_literal: true

require 'rails_helper'

RSpec.describe News::BatchFormatter do
  it 'formats batch lines without source labels' do
    article = create(
      :news_article,
      headline: 'Taiwan Semiconductor Stock Smashes 52-Week High After Blowout January Sales',
      source: 'benzinga',
      published_at: Time.zone.parse('2026-02-10 14:30:00 UTC')
    )
    create(:news_symbol, news_article: article, symbol: 'TSM')

    text = described_class.new([article]).call

    expect(text).to include('1. TSM | 14:30 |')
    expect(text.downcase).not_to include('benzinga')
  end
end
