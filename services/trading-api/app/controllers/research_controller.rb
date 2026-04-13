# frozen_string_literal: true

class ResearchController < ActionController::Base
  layout "application"

  def show
    ticker = params[:ticker].to_s.upcase

    unless ticker.match?(/\A[A-Z]{1,5}\z/)
      render plain: "Invalid ticker", status: :bad_request
      return
    end

    result = Dashboard::ResearchService.for_ticker(ticker)

    @ticker = ticker
    @content = result[:content]
    @error = result[:error]
  end
end
