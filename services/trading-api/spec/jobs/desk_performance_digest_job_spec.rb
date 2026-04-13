# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DeskPerformanceDigestJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  describe '#perform' do
    it 'publishes a desk performance digest event for the current ET hour slot' do
      travel_to Time.find_zone!("Eastern Time (US & Canada)").parse("2026-04-11 08:10:00") do
        expect do
          described_class.perform_now
        end.to change(OutboxEvent.where(event_type: 'desk_performance_digest'), :count).by(1)

        event = OutboxEvent.order(:id).last
        expect(event.sequence_key).to eq('perf-digest-20260411-08')
      end
    end
  end
end
