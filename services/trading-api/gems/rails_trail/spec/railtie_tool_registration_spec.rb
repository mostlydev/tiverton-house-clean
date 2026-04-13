require "spec_helper"

require "rails"
require "action_controller"
require "rails_trail"

RSpec.describe "trail_tool on ActionController" do
  before(:all) do
    ActionController::API.extend(RailsTrail::ToolRegistration) unless ActionController::API.respond_to?(:trail_tool)
  end

  let(:fake_controller) do
    Class.new(ActionController::API) do
      trail_tool :index, scope: :agent
    end
  end

  it "makes trail_tool available on API controllers" do
    expect(fake_controller._trail_tools).to include(index: hash_including(scope: :agent))
  end
end
