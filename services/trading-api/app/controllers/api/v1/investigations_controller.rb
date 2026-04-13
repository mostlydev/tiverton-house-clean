# frozen_string_literal: true

module Api
  module V1
    class InvestigationsController < ApplicationController
      before_action :require_research_writer_api_principal!, only: [:create, :update]

      # GET /api/v1/investigations
      def index
        scope = Investigation.all
        scope = scope.where(status: params[:status]) if params[:status].present?

        render json: scope.order(updated_at: :desc).map { |inv| investigation_json(inv) }
      end

      # GET /api/v1/investigations/:id
      def show
        investigation = Investigation.find(params[:id])
        render json: investigation_json(investigation)
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Investigation not found" }, status: :not_found
      end

      # POST /api/v1/investigations
      def create
        investigation = Investigation.new(investigation_params)
        if investigation.save
          render json: investigation_json(investigation), status: :created
        else
          render json: { error: investigation.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/investigations/:id
      def update
        investigation = Investigation.find(params[:id])
        if investigation.update(investigation_params)
          render json: investigation_json(investigation)
        else
          render json: { error: investigation.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Investigation not found" }, status: :not_found
      end

      # GET /api/v1/investigations/:id/entities
      def entities
        investigation = Investigation.find(params[:id])
        links = investigation.investigation_entities.includes(:research_entity)

        render json: {
          investigation: investigation_json(investigation),
          entities: links.map { |link|
            e = link.research_entity
            {
              id: e.id,
              name: e.name,
              ticker: e.ticker,
              entity_type: e.entity_type,
              role: link.role,
              summary: e.summary
            }
          }
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Investigation not found" }, status: :not_found
      end

      private

      def investigation_params
        params.require(:investigation).permit(:title, :status, :thesis, :recommendation)
      end

      def investigation_json(investigation)
        {
          id: investigation.id,
          title: investigation.title,
          status: investigation.status,
          thesis: investigation.thesis,
          recommendation: investigation.recommendation,
          entity_count: investigation.investigation_entities.count,
          created_at: investigation.created_at&.iso8601,
          updated_at: investigation.updated_at&.iso8601
        }
      end
    end
  end
end
