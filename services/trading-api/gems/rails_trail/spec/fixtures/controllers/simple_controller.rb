class SimpleController
  def create
    @thing = Thing.new(thing_params)
  end

  def show
    @thing = Thing.find(params[:id])
  end

  private

  def thing_params
    params.require(:thing).permit(:name, :color, :qty)
  end
end
