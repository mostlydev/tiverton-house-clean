module Admin
  class PositionsController < BaseController
    def index
      @positions = Position.includes(:agent)
                          .order(updated_at: :desc)
                          .limit(100)

      if params[:agent_id].present?
        @positions = @positions.where(agent_id: params[:agent_id])
      end
    end

    def show
      @position = Position.find(params[:id])
      @lots = PositionLot.where(
        agent_id: @position.agent_id,
        ticker: @position.ticker
      ).order(acquired_at: :desc)
    end
  end
end
