# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::V1::TradesController, type: :controller do
  before do
    allow(controller).to receive(:require_local_request).and_return(true)
    allow(DiscordService).to receive(:post_to_trading_floor)
    allow(NotificationDedupeService).to receive(:allow?).and_return(true)
    allow(AppConfig).to receive(:discord_notification_dedupe_seconds).and_return(300)
    allow(AppConfig).to receive(:trading_api_internal_token).and_return("internal-token")
    allow(AppConfig).to receive(:trading_api_agent_tokens).and_return(
      "logan" => "logan-token",
      "westin" => "westin-token"
    )
  end

  describe "POST #create" do
    it "posts proposal failure with requester mention for rejected submissions" do
      agent = create(:agent, :logan)
      request.headers["Authorization"] = "Bearer logan-token"

      post :create, params: {
        trade: {
          agent_id: agent.agent_id,
          ticker: "AAPL",
          side: "BUY",
          thesis: "Missing qty/amount"
        }
      }, format: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(DiscordService).to have_received(:post_to_trading_floor).with(
        hash_including(content: include("[PROPOSAL FAILED]"))
      )
      expect(DiscordService).to have_received(:post_to_trading_floor).with(
        hash_including(content: include("Requester: <@1464522019822375016> (logan)"))
      )
    end

    it "posts immediate sizing remediation guidance for missing qty or amount" do
      agent = create(:agent, :logan)
      request.headers["Authorization"] = "Bearer logan-token"

      post :create, params: {
        trade: {
          agent_id: agent.agent_id,
          ticker: "AAPL",
          side: "BUY",
          thesis: "Missing qty/amount"
        }
      }, format: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(DiscordService).to have_received(:post_to_trading_floor).with(
        hash_including(content: include("add qty_requested or amount_requested"))
      )
      expect(DiscordService).to have_received(:post_to_trading_floor).with(
        hash_including(content: include("resubmit immediately"))
      )
    end

    it "does not post proposal failure notification when create succeeds" do
      agent = create(:agent, :logan)
      request.headers["Authorization"] = "Bearer logan-token"

      post :create, params: {
        trade: {
          agent_id: agent.agent_id,
          ticker: "AAPL",
          side: "SELL",
          qty_requested: 1,
          thesis: "SHORT_OK test sell"
        }
      }, format: :json

      expect(response).to have_http_status(:created)
      expect(DiscordService).not_to have_received(:post_to_trading_floor).with(
        hash_including(content: include("[PROPOSAL FAILED]"))
      )
      expect(JSON.parse(response.body)["agent_id"]).to eq(agent.agent_id)
    end

    it "maps manual trailing fields into thesis without setting executable trailing params" do
      agent = create(:agent, :logan)
      request.headers["Authorization"] = "Bearer logan-token"

      post :create, params: {
        trade: {
          agent_id: agent.agent_id,
          ticker: "AAPL",
          side: "BUY",
          qty_requested: 1,
          manual_trail_percent: 3,
          thesis: "RESEARCH_OK breakout continuation"
        }
      }, format: :json

      expect(response).to have_http_status(:created)

      body = JSON.parse(response.body)
      expect(body["trail_percent"]).to be_nil
      expect(body["trail_amount"]).to be_nil
      expect(body["thesis"]).to include("RESEARCH_OK breakout continuation")
      expect(body["thesis"]).to include("Advisory trailing plan: manual trail 3%.")
    end

    it "accepts legacy trail_percent on MARKET orders by treating it as an advisory trail note" do
      agent = create(:agent, :logan)
      request.headers["Authorization"] = "Bearer logan-token"

      post :create, params: {
        trade: {
          agent_id: agent.agent_id,
          ticker: "AAPL",
          side: "BUY",
          qty_requested: 1,
          order_type: "MARKET",
          trail_percent: 3,
          thesis: "RESEARCH_OK breakout continuation"
        }
      }, format: :json

      expect(response).to have_http_status(:created)

      body = JSON.parse(response.body)
      expect(body["trail_percent"]).to be_nil
      expect(body["trail_amount"]).to be_nil
      expect(body["thesis"]).to include("Advisory trailing plan: manual trail 3%.")
    end

    it "rejects create when submitted agent_id does not match authenticated caller" do
      create(:agent, :logan)
      other_agent = create(:agent, :westin)
      request.headers["Authorization"] = "Bearer logan-token"

      post :create, params: {
        trade: {
          agent_id: other_agent.agent_id,
          ticker: "AAPL",
          side: "SELL",
          qty_requested: 1,
          thesis: "SHORT_OK test sell"
        }
      }, format: :json

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body).dig("details", "agent_id")).to include("authenticated caller")
    end
  end
end
