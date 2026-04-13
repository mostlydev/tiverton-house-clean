class NoRequireController
  def create
    @thing = Thing.new(params.permit(:name, :color))
  end
end
