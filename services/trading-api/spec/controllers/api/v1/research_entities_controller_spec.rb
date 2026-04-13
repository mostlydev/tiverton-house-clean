# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::ResearchEntitiesController, type: :controller do
  before do
    allow(controller).to receive(:require_local_request).and_return(true)
  end

  describe 'GET #index' do
    let!(:apple) { create(:research_entity, name: "Apple Inc", ticker: "AAPL", entity_type: "company") }
    let!(:cook) { create(:research_entity, :person, name: "Tim Cook") }
    let!(:msft) { create(:research_entity, name: "Microsoft Corp", ticker: "MSFT", entity_type: "company") }

    it 'returns all entities' do
      get :index, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.size).to eq(3)
    end

    it 'filters by entity_type' do
      get :index, params: { entity_type: "company" }, format: :json

      json = JSON.parse(response.body)
      expect(json.size).to eq(2)
      expect(json.map { |e| e["entity_type"] }.uniq).to eq(["company"])
    end

    it 'filters by ticker' do
      get :index, params: { ticker: "AAPL" }, format: :json

      json = JSON.parse(response.body)
      expect(json.size).to eq(1)
      expect(json.first["ticker"]).to eq("AAPL")
    end
  end

  describe 'GET #show' do
    let!(:entity) { create(:research_entity) }

    it 'returns the entity' do
      get :show, params: { id: entity.id }, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["id"]).to eq(entity.id)
      expect(json["name"]).to eq(entity.name)
    end

    it 'returns 404 for missing entity' do
      get :show, params: { id: 999999 }, format: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST #create' do
    it 'creates a new entity' do
      post :create, params: {
        research_entity: {
          name: "NVIDIA Corp",
          ticker: "NVDA",
          entity_type: "company",
          summary: "GPU manufacturer"
        }
      }, format: :json

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["name"]).to eq("NVIDIA Corp")
      expect(json["ticker"]).to eq("NVDA")
    end

    it 'returns errors for invalid entity' do
      post :create, params: {
        research_entity: { name: "", entity_type: "invalid" }
      }, format: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects trader principals' do
      create(:agent, agent_id: "weston", role: "trader")
      allow(AppConfig).to receive(:trading_api_internal_token).and_return("internal-token")
      allow(AppConfig).to receive(:trading_api_agent_tokens).and_return("weston" => "weston-token")
      request.headers["Authorization"] = "Bearer weston-token"

      post :create, params: {
        research_entity: {
          name: "NVIDIA Corp",
          ticker: "NVDA",
          entity_type: "company"
        }
      }, format: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'allows analyst principals' do
      create(:agent, agent_id: "allen", role: "analyst")
      allow(AppConfig).to receive(:trading_api_internal_token).and_return("internal-token")
      allow(AppConfig).to receive(:trading_api_agent_tokens).and_return("allen" => "allen-token")
      request.headers["Authorization"] = "Bearer allen-token"

      post :create, params: {
        research_entity: {
          name: "NVIDIA Corp",
          ticker: "NVDA",
          entity_type: "company"
        }
      }, format: :json

      expect(response).to have_http_status(:created)
    end
  end

  describe 'PATCH #update' do
    let!(:entity) { create(:research_entity) }

    it 'updates the entity' do
      patch :update, params: {
        id: entity.id,
        research_entity: { summary: "Updated summary" }
      }, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["summary"]).to eq("Updated summary")
    end
  end

  describe 'GET #graph' do
    let!(:apple) { create(:research_entity, name: "Apple Inc", ticker: "AAPL") }
    let!(:msft) { create(:research_entity, name: "Microsoft Corp", ticker: "MSFT") }
    let!(:rel) do
      create(:research_relationship,
        source_entity: apple,
        target_entity: msft,
        relationship_type: "competes_with",
        strength: "strong"
      )
    end

    it 'returns entity with relationships and related entities' do
      get :graph, params: { id: apple.id }, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)

      expect(json["entity"]["id"]).to eq(apple.id)
      expect(json["relationships"].size).to eq(1)
      expect(json["relationships"].first["relationship_type"]).to eq("competes_with")
      expect(json["relationships"].first["source_name"]).to eq("Apple Inc")
      expect(json["relationships"].first["target_name"]).to eq("Microsoft Corp")
      expect(json["related_entities"].size).to eq(1)
      expect(json["related_entities"].first["ticker"]).to eq("MSFT")
    end

    it 'returns 404 for missing entity' do
      get :graph, params: { id: 999999 }, format: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
