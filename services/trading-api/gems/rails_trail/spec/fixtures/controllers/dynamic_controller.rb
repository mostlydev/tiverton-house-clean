class DynamicController
  def create
    permitted = thing_params
    permitted.merge!(extra: :data)
    @thing = Thing.new(permitted)
  end

  private

  def thing_params
    base = [:name]
    base << :color if some_flag?
    params.require(:thing).permit(*base)
  end
end
