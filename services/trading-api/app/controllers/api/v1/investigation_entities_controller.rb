# frozen_string_literal: true

module Api
  module V1
    class InvestigationEntitiesController < ApplicationController
      before_action :require_research_writer_api_principal!, only: [:create, :destroy]

      # POST /api/v1/investigation_entities
      def create
        link = InvestigationEntity.new(link_params)
        if link.save
          render json: link_json(link), status: :created
        else
          render json: { error: link.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/investigation_entities/:id
      def destroy
        link = InvestigationEntity.find(params[:id])
        link.destroy!
        render json: { deleted: true }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Investigation entity link not found" }, status: :not_found
      end

      private

      def link_params
        params.require(:investigation_entity).permit(:investigation_id, :research_entity_id, :role)
      end

      def link_json(link)
        {
          id: link.id,
          investigation_id: link.investigation_id,
          research_entity_id: link.research_entity_id,
          role: link.role
        }
      end
    end
  end
end
