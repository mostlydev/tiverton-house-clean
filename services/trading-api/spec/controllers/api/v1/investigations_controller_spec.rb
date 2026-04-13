# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::InvestigationsController, type: :controller do
  before do
    allow(controller).to receive(:require_local_request).and_return(true)
  end

  describe 'GET #index' do
    let!(:active_inv) { create(:investigation, title: "AI Chip Analysis", status: "active") }
    let!(:completed_inv) { create(:investigation, :completed, title: "EV Market Study") }

    it 'returns all investigations' do
      get :index, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.size).to eq(2)
    end

    it 'filters by status' do
      get :index, params: { status: "active" }, format: :json

      json = JSON.parse(response.body)
      expect(json.size).to eq(1)
      expect(json.first["status"]).to eq("active")
    end

    it 'includes entity_count' do
      entity = create(:research_entity)
      create(:investigation_entity, investigation: active_inv, research_entity: entity)

      get :index, format: :json

      json = JSON.parse(response.body)
      inv = json.find { |i| i["id"] == active_inv.id }
      expect(inv["entity_count"]).to eq(1)
    end
  end

  describe 'GET #show' do
    let!(:investigation) { create(:investigation) }

    it 'returns the investigation' do
      get :show, params: { id: investigation.id }, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["id"]).to eq(investigation.id)
      expect(json["title"]).to eq(investigation.title)
    end

    it 'returns 404 for missing investigation' do
      get :show, params: { id: 999999 }, format: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST #create' do
    it 'creates a new investigation' do
      post :create, params: {
        investigation: {
          title: "Supply Chain Analysis",
          status: "active",
          thesis: "Supply chain disruption thesis"
        }
      }, format: :json

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["title"]).to eq("Supply Chain Analysis")
      expect(json["status"]).to eq("active")
    end

    it 'returns errors for invalid investigation' do
      post :create, params: {
        investigation: { title: "", status: "bogus" }
      }, format: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'PATCH #update' do
    let!(:investigation) { create(:investigation) }

    it 'updates the investigation' do
      patch :update, params: {
        id: investigation.id,
        investigation: { status: "completed", recommendation: "Buy NVDA" }
      }, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["status"]).to eq("completed")
      expect(json["recommendation"]).to eq("Buy NVDA")
    end
  end

  describe 'GET #entities' do
    let!(:investigation) { create(:investigation) }
    let!(:entity) { create(:research_entity, name: "Apple Inc", ticker: "AAPL") }
    let!(:link) { create(:investigation_entity, investigation: investigation, research_entity: entity, role: "target") }

    it 'returns investigation with linked entities' do
      get :entities, params: { id: investigation.id }, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)

      expect(json["investigation"]["id"]).to eq(investigation.id)
      expect(json["entities"].size).to eq(1)
      expect(json["entities"].first["name"]).to eq("Apple Inc")
      expect(json["entities"].first["role"]).to eq("target")
    end

    it 'returns 404 for missing investigation' do
      get :entities, params: { id: 999999 }, format: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
