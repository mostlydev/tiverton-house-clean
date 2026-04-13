# frozen_string_literal: true

class NotesController < ActionController::Base
  layout "application"

  TRADERS = DashboardController::TRADERS

  def show
    agent = params[:agent].to_s.downcase
    ticker = params[:ticker].to_s.upcase

    unless agent.match?(/\A[a-z]+\z/)
      render plain: "Invalid agent", status: :bad_request
      return
    end

    unless ticker.match?(/\A[A-Z]{1,5}\z/)
      render plain: "Invalid ticker", status: :bad_request
      return
    end

    @trader = TRADERS[agent]

    unless @trader
      render plain: "Agent not found", status: :not_found
      return
    end

    @trader = @trader.merge(id: agent)
    @ticker = ticker

    result = Dashboard::AgentNotesService.for_agent_ticker(agent, ticker)
    @content = result[:content]
    @error = result[:error]
  end
end
