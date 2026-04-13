# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::V1::TradesController, type: :controller do
  let!(:agent) { create(:agent) }

  before do
    allow(controller).to receive(:require_local_request).and_return(true)
    allow(AppConfig).to receive(:trading_api_internal_token).and_return("internal-token")
    allow(AppConfig).to receive(:trading_api_agent_tokens).and_return(
      "tiverton" => "tiverton-token",
      agent.agent_id => "agent-token",
      "other-agent" => "other-token"
    )
  end

  describe "POST #approve" do
    it "allows approval without prior confirmation (independent sign-offs)" do
      trade = create(:trade, :proposed, agent: agent, confirmed_at: nil)
      allow(Trades::ExecutionSchedulerService).to receive_message_chain(:new, :call).and_return(true)
      request.headers["Authorization"] = "Bearer tiverton-token"

      post :approve, params: { id: trade.trade_id, approved_by: "tiverton" }, format: :json

      expect(response).to have_http_status(:ok)
      expect(trade.reload.status).to eq("APPROVED")
      expect(trade.approved_by).to eq("tiverton")
      body = JSON.parse(response.body)
      expect(body.dig("next_action", "confirmation_missing")).to eq(true)
    end

    it "allows approval after confirmation" do
      trade = create(:trade, :proposed, agent: agent, confirmed_at: Time.current)
      allow(Trades::ExecutionSchedulerService).to receive_message_chain(:new, :call).and_return(true)
      request.headers["Authorization"] = "Bearer tiverton-token"

      post :approve, params: { id: trade.trade_id, approved_by: "tiverton" }, format: :json

      expect(response).to have_http_status(:ok)
      expect(trade.reload.status).to eq("APPROVED")
      expect(trade.approved_by).to eq("tiverton")
      body = JSON.parse(response.body)
      expect(body.dig("next_action", "complete")).to eq(true)
    end
  end

  describe "POST #confirm" do
    it "schedules execution when an approved trade gets confirmed" do
      trade = create(
        :trade,
        agent: agent,
        status: "APPROVED",
        approved_by: "tiverton",
        approved_at: 2.minutes.ago,
        confirmed_at: nil
      )
      scheduler = instance_double(Trades::ExecutionSchedulerService, call: true)
      allow(Trades::ExecutionSchedulerService).to receive(:new).and_return(scheduler)
      request.headers["Authorization"] = "Bearer agent-token"

      post :confirm, params: { id: trade.trade_id }, format: :json

      expect(response).to have_http_status(:ok)
      expect(trade.reload.confirmed_at).to be_present
      expect(Trades::ExecutionSchedulerService).to have_received(:new).with(instance_of(Trade))
      expect(scheduler).to have_received(:call)
    end

    it "does not schedule execution while still awaiting approval" do
      trade = create(:trade, :proposed, agent: agent, confirmed_at: nil)
      allow(Trades::ExecutionSchedulerService).to receive(:new)
      request.headers["Authorization"] = "Bearer agent-token"

      post :confirm, params: { id: trade.trade_id }, format: :json

      expect(response).to have_http_status(:ok)
      expect(trade.reload.status).to eq("PROPOSED")
      expect(trade.confirmed_at).to be_present
      expect(Trades::ExecutionSchedulerService).not_to have_received(:new)
      body = JSON.parse(response.body)
      expect(body.dig("next_action", "actor")).to eq("tiverton")
      expect(body.dig("next_action", "action")).to eq("approve")
    end

    it "rejects confirmation from another agent" do
      trade = create(:trade, :proposed, agent: agent, confirmed_at: nil)
      request.headers["Authorization"] = "Bearer other-token"

      post :confirm, params: { id: trade.trade_id }, format: :json

      expect(response).to have_http_status(:forbidden)
      expect(trade.reload.confirmed_at).to be_nil
    end
  end
end
