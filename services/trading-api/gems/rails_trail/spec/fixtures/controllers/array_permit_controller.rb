class ArrayPermitController
  def create
    @thing = Thing.new(thing_params)
  end

  private

  def thing_params
    params.require(:watchlist).permit(:agent_id, :ticker, tickers: [])
  end
end
