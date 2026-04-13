# frozen_string_literal: true

require 'rails_helper'

RSpec.describe OutboxProcessorJob, type: :job do
  describe '#perform' do
    it 'dispatches desk performance digest events to Discord' do
      OutboxEvent.publish!(
        event_type: 'desk_performance_digest',
        aggregate_type: 'System',
        aggregate_id: 0,
        sequence_key: 'perf-digest-20260411-08',
        payload: {}
      )

      allow(Desk::PerformanceSummaryService).to receive(:call).and_return(
        desk: { overall_total_pnl: 1_940.86, wtd_realized_pnl: 187.0, mtd_realized_pnl: 47.0 },
        traders: [{ agent_id: 'weston', name: 'Weston', total_pnl_overall: 2_041.98 }]
      )
      allow(Desk::PerformanceDigestFormatter).to receive(:format).and_return("Desk performance: overall +$1.94k")
      allow(DiscordService).to receive(:post_to_trading_floor)

      described_class.perform_now

      event = OutboxEvent.order(:id).last
      expect(event.status).to eq('completed')
      expect(DiscordService).to have_received(:post_to_trading_floor).with(
        content: "Desk performance: overall +$1.94k",
        allowed_mentions: { parse: [] }
      )
    end
  end
end
