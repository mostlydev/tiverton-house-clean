# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Trades::StaleTradeService do
  let(:agent) { create(:agent) }

  before do
    mock_all_external_services!
    allow(OutboxPublisherService).to receive(:trade_timeout!).and_return(true)
    allow(OutboxPublisherService).to receive(:trade_stale_proposal!).and_return(true)
    allow(OutboxPublisherService).to receive(:trade_next_action_nudge!).and_return(true)
    allow(OutboxPublisherService).to receive(:trade_approved!).and_return(true)
    allow(Trades::ExecutionSchedulerService).to receive_message_chain(:new, :call).and_return(true)
  end

  describe '#cancel_stale_proposals' do
    it 'cancels proposals older than the timeout' do
      stale = create(:trade, agent: agent, status: 'PROPOSED',
                     created_at: (described_class::PROPOSAL_TIMEOUT + 1.minute).ago)
      fresh = create(:trade, agent: agent, status: 'PROPOSED', created_at: 1.minute.ago)

      described_class.new.cancel_stale_proposals

      expect(stale.reload.status).to eq('CANCELLED')
      expect(stale.denial_reason).to eq('STALE_PROPOSAL')
      expect(fresh.reload.status).to eq('PROPOSED')
    end

    it 'creates STALE_PROPOSAL trade event' do
      stale = create(:trade, agent: agent, status: 'PROPOSED',
                     created_at: (described_class::PROPOSAL_TIMEOUT + 1.minute).ago)

      described_class.new.cancel_stale_proposals

      event = stale.trade_events.find_by(event_type: 'STALE_PROPOSAL')
      expect(event).to be_present
      expect(event.actor).to eq('system')
    end

    it 'notifies via outbox' do
      stale = create(:trade, agent: agent, status: 'PROPOSED',
                     created_at: (described_class::PROPOSAL_TIMEOUT + 1.minute).ago)

      described_class.new.cancel_stale_proposals

      expect(OutboxPublisherService).to have_received(:trade_stale_proposal!).with(stale)
    end

    it 'auto-approves stale stop-loss proposals instead of cancelling' do
      stale = create(:trade, agent: agent, status: 'PROPOSED', side: 'SELL',
                     thesis: 'Stop loss exit',
                     created_at: (described_class::PROPOSAL_TIMEOUT + 1.minute).ago)

      described_class.new.cancel_stale_proposals

      expect(stale.reload.status).to eq('APPROVED')
      expect(stale.approved_by).to eq('system_stop_loss')
      expect(stale.confirmed_at).to be_present
      expect(OutboxPublisherService).not_to have_received(:trade_stale_proposal!).with(stale)
    end
  end

  describe '#timeout_stale_executions' do
    it 'fails executions without order ID older than timeout' do
      stale = create(:trade, :executing, agent: agent, alpaca_order_id: nil,
                     updated_at: (described_class::EXECUTION_TIMEOUT + 1.minute).ago)

      described_class.new.timeout_stale_executions

      expect(stale.reload.status).to eq('FAILED')
      expect(stale.execution_error).to include('Execution timeout')
    end

    it 'does not timeout executions with alpaca order ID' do
      has_order = create(:trade, :executing, agent: agent,
                         alpaca_order_id: 'order-123',
                         updated_at: (described_class::EXECUTION_TIMEOUT + 1.minute).ago)

      described_class.new.timeout_stale_executions

      expect(has_order.reload.status).to eq('EXECUTING')
    end

    it 'creates TIMEOUT trade event' do
      stale = create(:trade, :executing, agent: agent, alpaca_order_id: nil,
                     updated_at: (described_class::EXECUTION_TIMEOUT + 1.minute).ago)

      described_class.new.timeout_stale_executions

      event = stale.trade_events.find_by(event_type: 'TIMEOUT')
      expect(event).to be_present
    end
  end

  describe '#request_reconfirmation' do
    it 'sends reconfirmation for approved trades without confirmation' do
      stale_approved = create(:trade, agent: agent, status: 'APPROVED',
                              approved_by: 'tiverton',
                              approved_at: (described_class::APPROVAL_TIMEOUT + 1.minute).ago,
                              confirmed_at: nil)

      described_class.new.request_reconfirmation

      expect(OutboxPublisherService).to have_received(:trade_next_action_nudge!).with(stale_approved)
    end

    it 'nudges queued trades awaiting confirmation' do
      queued = create(:trade, agent: agent, status: 'QUEUED',
                      approved_by: 'tiverton',
                      approved_at: (described_class::APPROVAL_TIMEOUT + 1.minute).ago,
                      confirmed_at: nil)

      described_class.new.request_reconfirmation

      expect(OutboxPublisherService).to have_received(:trade_next_action_nudge!).with(queued)
    end

    it 'does not send reconfirmation for confirmed trades' do
      confirmed = create(:trade, :confirmed, agent: agent,
                         approved_at: (described_class::APPROVAL_TIMEOUT + 1.minute).ago)

      described_class.new.request_reconfirmation

      expect(OutboxPublisherService).not_to have_received(:trade_next_action_nudge!)
    end

    it 'does not nudge recently approved trades (timer reset on approval action)' do
      fresh = create(:trade, agent: agent, status: 'APPROVED',
                     approved_by: 'tiverton',
                     approved_at: 1.minute.ago,
                     confirmed_at: nil)

      described_class.new.request_reconfirmation

      expect(OutboxPublisherService).not_to have_received(:trade_next_action_nudge!).with(fresh)
    end
  end

  describe '#nudge_pending_approvals' do
    it 'nudges confirmed trades still in PROPOSED state' do
      stuck = create(:trade, agent: agent, status: 'PROPOSED',
                     confirmed_at: (described_class::APPROVAL_TIMEOUT + 1.minute).ago)

      described_class.new.nudge_pending_approvals

      expect(OutboxPublisherService).to have_received(:trade_next_action_nudge!).with(stuck)
    end

    it 'nudges unconfirmed proposals older than timeout' do
      stale = create(:trade, agent: agent, status: 'PROPOSED',
                     confirmed_at: nil,
                     created_at: (described_class::APPROVAL_TIMEOUT + 1.minute).ago)

      described_class.new.nudge_pending_approvals

      expect(OutboxPublisherService).to have_received(:trade_next_action_nudge!).with(stale)
    end

    it 'does not nudge immediately after trader confirmation (timer reset on confirmation action)' do
      waiting = create(:trade, agent: agent, status: 'PROPOSED',
                       created_at: (described_class::APPROVAL_TIMEOUT + 2.minutes).ago,
                       confirmed_at: 1.minute.ago)

      described_class.new.nudge_pending_approvals

      expect(OutboxPublisherService).not_to have_received(:trade_next_action_nudge!).with(waiting)
    end

    it 'auto-approves confirmed stop-loss trades instead of nudging' do
      stuck = create(:trade, agent: agent, status: 'PROPOSED', side: 'SELL',
                     thesis: 'Stop loss exit',
                     confirmed_at: (described_class::APPROVAL_TIMEOUT + 1.minute).ago)

      described_class.new.nudge_pending_approvals

      expect(stuck.reload.status).to eq('APPROVED')
      expect(stuck.approved_by).to eq('system_stop_loss')
      expect(OutboxPublisherService).not_to have_received(:trade_next_action_nudge!).with(stuck)
    end
  end

  describe '#call' do
    it 'runs all cleanup tasks' do
      service = described_class.new
      allow(service).to receive(:cancel_stale_proposals)
      allow(service).to receive(:timeout_stale_executions)
      allow(service).to receive(:request_reconfirmation)
      allow(service).to receive(:nudge_pending_approvals)

      service.call

      expect(service).to have_received(:cancel_stale_proposals)
      expect(service).to have_received(:timeout_stale_executions)
      expect(service).to have_received(:request_reconfirmation)
      expect(service).to have_received(:nudge_pending_approvals)
    end
  end
end
