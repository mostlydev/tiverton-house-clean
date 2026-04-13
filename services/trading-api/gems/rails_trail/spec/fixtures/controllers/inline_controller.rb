class InlineController
  def create
    @thing = Thing.new(params.require(:thing).permit(:name, :color))
  end
end
