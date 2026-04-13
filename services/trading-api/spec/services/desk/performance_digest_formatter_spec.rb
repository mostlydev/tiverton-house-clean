# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Desk::PerformanceDigestFormatter, type: :service do
  describe '.format' do
    it 'renders a deterministic two-line digest' do
      summary = {
        desk: {
          overall_total_pnl: 1_940.86,
          wtd_realized_pnl: 187.0,
          mtd_realized_pnl: 47.0
        },
        traders: [
          { agent_id: 'weston', name: 'Weston', total_pnl_overall: 2_041.98 },
          { agent_id: 'logan', name: 'Logan', total_pnl_overall: -87.84 },
          { agent_id: 'gerrard', name: 'Gerrard', total_pnl_overall: -13.12 }
        ]
      }

      expect(described_class.format(summary)).to eq(
        "Desk performance: overall +$1.94k | WTD realized +$187 | MTD realized +$47\n" \
        "Weston +$2.04k | Logan -$88 | Gerrard -$13"
      )
    end
  end
end
