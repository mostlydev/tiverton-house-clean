# frozen_string_literal: true

module Api
  module V1
    class ResearchNotesController < ApplicationController
      before_action :require_research_writer_api_principal!, only: :create

      # GET /api/v1/research_notes
      def index
        scope = ResearchNote.all
        if params[:notable_type].present? && params[:notable_id].present?
          scope = scope.where(notable_type: params[:notable_type], notable_id: params[:notable_id])
        end
        scope = scope.where(note_type: params[:note_type]) if params[:note_type].present?

        render json: scope.order(created_at: :desc).map { |n| note_json(n) }
      end

      # POST /api/v1/research_notes
      def create
        note = ResearchNote.new(note_params)
        if note.save
          render json: note_json(note), status: :created
        else
          render json: { error: note.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      private

      def note_params
        params.require(:research_note).permit(:notable_type, :notable_id, :note_type, :content)
      end

      def note_json(note)
        {
          id: note.id,
          notable_type: note.notable_type,
          notable_id: note.notable_id,
          note_type: note.note_type,
          content: note.content,
          created_at: note.created_at&.iso8601
        }
      end
    end
  end
end
