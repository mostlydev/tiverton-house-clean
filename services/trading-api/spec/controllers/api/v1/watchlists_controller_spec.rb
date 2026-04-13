# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::WatchlistsController, type: :controller do
  let!(:agent) { create(:agent) }

  before do
    allow(controller).to receive(:require_local_request).and_return(true)
  end

  describe 'GET #index' do
    it 'returns empty watchlist' do
      get :index, params: { agent_id: agent.agent_id }, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['agent_id']).to eq(agent.agent_id)
      expect(json['watchlist']).to eq([])
    end

    it 'returns watchlist entries' do
      Watchlist.create!(agent: agent, ticker: 'AAPL', source: 'api')
      Watchlist.create!(agent: agent, ticker: 'NVDA', source: 'file')

      get :index, params: { agent_id: agent.agent_id }, format: :json

      json = JSON.parse(response.body)
      tickers = json['watchlist'].map { |w| w['ticker'] }
      expect(tickers).to contain_exactly('AAPL', 'NVDA')
    end

    it 'filters by source' do
      Watchlist.create!(agent: agent, ticker: 'AAPL', source: 'api')
      Watchlist.create!(agent: agent, ticker: 'NVDA', source: 'file')

      get :index, params: { agent_id: agent.agent_id, source: 'api' }, format: :json

      json = JSON.parse(response.body)
      tickers = json['watchlist'].map { |w| w['ticker'] }
      expect(tickers).to eq(['AAPL'])
    end

    it 'returns 422 without agent_id' do
      get :index, format: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'returns 404 for unknown agent' do
      get :index, params: { agent_id: 'nonexistent' }, format: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST #create' do
    before do
      allow(controller).to receive(:current_api_principal).and_return(
        ApplicationController::ApiPrincipal.new(id: 'internal', type: :internal)
      )
      allow(Rails.logger).to receive(:warn)
    end

    it 'adds tickers to watchlist' do
      post :create, params: { watchlist: { agent_id: agent.agent_id, tickers: ['AAPL', 'NVDA'] } }, format: :json

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json['added']).to contain_exactly('AAPL', 'NVDA')
      expect(json['already_present']).to be_empty
      expect(agent.watchlists.count).to eq(2)
    end

    it 'accepts single ticker param' do
      post :create, params: { watchlist: { agent_id: agent.agent_id, ticker: 'TSLA' } }, format: :json

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json['added']).to eq(['TSLA'])
    end

    it 'reports already-present tickers' do
      Watchlist.create!(agent: agent, ticker: 'AAPL', source: 'api')

      post :create, params: { watchlist: { agent_id: agent.agent_id, tickers: ['AAPL', 'NVDA'] } }, format: :json

      json = JSON.parse(response.body)
      expect(json['added']).to eq(['NVDA'])
      expect(json['already_present']).to eq(['AAPL'])
    end

    it 'normalizes tickers to uppercase' do
      post :create, params: { watchlist: { agent_id: agent.agent_id, tickers: ['aapl'] } }, format: :json

      expect(response).to have_http_status(:created)
      expect(agent.watchlists.first.ticker).to eq('AAPL')
    end

    it 'deduplicates input tickers' do
      post :create, params: { watchlist: { agent_id: agent.agent_id, tickers: ['AAPL', 'AAPL'] } }, format: :json

      json = JSON.parse(response.body)
      expect(json['added']).to eq(['AAPL'])
      expect(agent.watchlists.count).to eq(1)
    end

    it 'rejects empty tickers' do
      post :create, params: { watchlist: { agent_id: agent.agent_id, tickers: [] } }, format: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'sets source to api' do
      post :create, params: { watchlist: { agent_id: agent.agent_id, ticker: 'AAPL' } }, format: :json

      expect(agent.watchlists.first.source).to eq('api')
    end

    context 'authorization' do
      it 'allows agent to modify own watchlist' do
        allow(controller).to receive(:current_api_principal).and_return(
          ApplicationController::ApiPrincipal.new(id: agent.agent_id, type: :agent)
        )

        post :create, params: { watchlist: { agent_id: agent.agent_id, ticker: 'AAPL' } }, format: :json
        expect(response).to have_http_status(:created)
      end

      it 'allows coordinator to modify any watchlist' do
        allow(controller).to receive(:current_api_principal).and_return(
          ApplicationController::ApiPrincipal.new(id: 'tiverton', type: :coordinator)
        )

        post :create, params: { watchlist: { agent_id: agent.agent_id, ticker: 'AAPL' } }, format: :json
        expect(response).to have_http_status(:created)
      end

      it 'forces agent callers onto their own watchlist' do
        other = create(:agent)
        allow(controller).to receive(:current_api_principal).and_return(
          ApplicationController::ApiPrincipal.new(id: other.agent_id, type: :agent)
        )

        post :create, params: { watchlist: { agent_id: agent.agent_id, ticker: 'AAPL' } }, format: :json
        expect(response).to have_http_status(:created)
        expect(other.watchlists.where(ticker: 'AAPL')).to exist
        expect(agent.watchlists.where(ticker: 'AAPL')).not_to exist
      end

      it 'logs a warning when a caller supplies a mismatched agent_id' do
        other = create(:agent)
        allow(controller).to receive(:current_api_principal).and_return(
          ApplicationController::ApiPrincipal.new(id: other.agent_id, type: :agent)
        )

        post :create, params: { watchlist: { agent_id: agent.agent_id, ticker: 'AAPL' } }, format: :json

        expect(Rails.logger).to have_received(:warn).with(include("Ignoring supplied agent_id"))
      end
    end
  end

  describe 'DELETE #destroy' do
    before do
      allow(controller).to receive(:current_api_principal).and_return(
        ApplicationController::ApiPrincipal.new(id: 'internal', type: :internal)
      )
    end

    it 'removes tickers from watchlist' do
      Watchlist.create!(agent: agent, ticker: 'AAPL', source: 'api')
      Watchlist.create!(agent: agent, ticker: 'NVDA', source: 'api')

      delete :destroy, params: { watchlist: { agent_id: agent.agent_id, tickers: ['AAPL'] } }, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['removed']).to eq(['AAPL'])
      expect(json['not_found']).to be_empty
      expect(agent.watchlists.count).to eq(1)
    end

    it 'removes across all sources' do
      Watchlist.create!(agent: agent, ticker: 'AAPL', source: 'api')
      Watchlist.create!(agent: agent, ticker: 'AAPL', source: 'file')

      delete :destroy, params: { watchlist: { agent_id: agent.agent_id, tickers: ['AAPL'] } }, format: :json

      json = JSON.parse(response.body)
      expect(json['removed']).to eq(['AAPL'])
      expect(agent.watchlists.where(ticker: 'AAPL').count).to eq(0)
    end

    it 'reports not-found tickers' do
      delete :destroy, params: { watchlist: { agent_id: agent.agent_id, tickers: ['AAPL'] } }, format: :json

      json = JSON.parse(response.body)
      expect(json['removed']).to be_empty
      expect(json['not_found']).to eq(['AAPL'])
    end

    it 'forces agent callers onto their own watchlist' do
      other = create(:agent)
      Watchlist.create!(agent: agent, ticker: 'AAPL', source: 'api')
      Watchlist.create!(agent: other, ticker: 'AAPL', source: 'api')
      allow(controller).to receive(:current_api_principal).and_return(
        ApplicationController::ApiPrincipal.new(id: other.agent_id, type: :agent)
      )

      delete :destroy, params: { watchlist: { agent_id: agent.agent_id, tickers: ['AAPL'] } }, format: :json

      expect(response).to have_http_status(:ok)
      expect(other.watchlists.where(ticker: 'AAPL')).not_to exist
      expect(agent.watchlists.where(ticker: 'AAPL')).to exist
    end
  end
end
