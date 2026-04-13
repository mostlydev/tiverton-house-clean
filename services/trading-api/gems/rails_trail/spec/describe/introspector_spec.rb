require "spec_helper"

require "action_controller"
require "action_dispatch"
require "rails_trail/describe/introspector"

RSpec.describe RailsTrail::Describe::Introspector do
  before do
    ActionController::API.extend(RailsTrail::ToolRegistration) unless ActionController::API.respond_to?(:trail_tool)
  end

  let(:fake_app) do
    Class.new do
      def self.routes
        @routes ||= ActionDispatch::Routing::RouteSet.new.tap do |routes|
          routes.draw do
            scope "/api/v1" do
              get "/things/:id", to: "api/v1/things#show"
              post "/things", to: "api/v1/things#create"
            end
          end
        end
      end
    end
  end

  before do
    stub_const("Api::V1::ThingsController", Class.new(ActionController::API) do
      trail_tool :show, scope: :agent
      trail_tool :create, scope: :agent, name: "make_thing"

      def show; end
      def create; end
    end)
    allow(RailsTrail.configuration).to receive(:api_prefix).and_return("/api/v1")
  end

  it "attaches DSL metadata to annotated routes" do
    data = described_class.new(rails_app: fake_app).introspect
    show_route = data[:routes].find { |route| route[:action] == "api/v1/things#show" }
    expect(show_route[:dsl]).to include(scope: :agent)
    expect(show_route[:controller_class]).to eq(Api::V1::ThingsController)
    expect(show_route[:controller_source_path]).to be_present
  end
end
