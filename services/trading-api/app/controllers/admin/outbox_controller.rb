module Admin
  class OutboxController < BaseController
    def index
      @events = OutboxEvent.order(created_at: :desc)
                          .limit(200)

      if params[:status].present?
        @events = @events.where(status: params[:status])
      end

      if params[:event_type].present?
        @events = @events.where(event_type: params[:event_type])
      end
    end

    def show
      @event = OutboxEvent.find(params[:id])
    end
  end
end
