# frozen_string_literal: true

module Api
  module V1
    class ResearchEntitiesController < ApplicationController
      before_action :require_research_writer_api_principal!, only: [:create, :update]

      # GET /api/v1/research_entities
      def index
        scope = ResearchEntity.all
        scope = scope.where(entity_type: params[:entity_type]) if params[:entity_type].present?
        scope = scope.by_ticker(params[:ticker].upcase) if params[:ticker].present?

        render json: scope.order(:name).map { |e| entity_json(e) }
      end

      # GET /api/v1/research_entities/:id
      def show
        entity = ResearchEntity.find(params[:id])
        render json: entity_json(entity)
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Research entity not found" }, status: :not_found
      end

      # POST /api/v1/research_entities
      def create
        entity = ResearchEntity.new(entity_params)
        if entity.save
          render json: entity_json(entity), status: :created
        else
          render json: { error: entity.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/research_entities/:id
      def update
        entity = ResearchEntity.find(params[:id])
        if entity.update(entity_params)
          render json: entity_json(entity)
        else
          render json: { error: entity.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Research entity not found" }, status: :not_found
      end

      # GET /api/v1/research_entities/:id/graph
      def graph
        entity = ResearchEntity.find(params[:id])

        relationships = entity.outgoing_relationships + entity.incoming_relationships
        related = entity.related_entities

        render json: {
          entity: entity_json(entity),
          relationships: relationships.map { |r| relationship_json(r) },
          related_entities: related.map { |e| entity_json(e) }
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Research entity not found" }, status: :not_found
      end

      private

      def entity_params
        params.require(:research_entity).permit(:name, :ticker, :entity_type, :summary, :last_researched_at, data: {})
      end

      def entity_json(entity)
        {
          id: entity.id,
          name: entity.name,
          ticker: entity.ticker,
          entity_type: entity.entity_type,
          summary: entity.summary,
          data: entity.data,
          last_researched_at: entity.last_researched_at&.iso8601,
          updated_at: entity.updated_at&.iso8601
        }
      end

      def relationship_json(rel)
        {
          id: rel.id,
          source_entity_id: rel.source_entity_id,
          target_entity_id: rel.target_entity_id,
          source_name: rel.source_entity.name,
          target_name: rel.target_entity.name,
          relationship_type: rel.relationship_type,
          description: rel.description,
          strength: rel.strength
        }
      end
    end
  end
end
