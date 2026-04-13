# frozen_string_literal: true

module Api
  module V1
    class ResearchRelationshipsController < ApplicationController
      before_action :require_research_writer_api_principal!, only: [:create, :destroy]

      # GET /api/v1/research_relationships
      def index
        scope = ResearchRelationship.all
        scope = scope.where(source_entity_id: params[:source_entity_id]) if params[:source_entity_id].present?
        scope = scope.where(target_entity_id: params[:target_entity_id]) if params[:target_entity_id].present?
        scope = scope.where(relationship_type: params[:relationship_type]) if params[:relationship_type].present?

        render json: scope.includes(:source_entity, :target_entity).map { |r| relationship_json(r) }
      end

      # POST /api/v1/research_relationships
      def create
        rel = ResearchRelationship.new(relationship_params)
        if rel.save
          render json: relationship_json(rel), status: :created
        else
          render json: { error: rel.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/research_relationships/:id
      def destroy
        rel = ResearchRelationship.find(params[:id])
        rel.destroy!
        render json: { deleted: true }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Research relationship not found" }, status: :not_found
      end

      private

      def relationship_params
        params.require(:research_relationship).permit(:source_entity_id, :target_entity_id, :relationship_type, :description, :strength)
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
