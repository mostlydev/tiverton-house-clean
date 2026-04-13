require "spec_helper"

require "rails_trail/tool_registration"

RSpec.describe RailsTrail::ToolRegistration do
  let(:controller_class) do
    Class.new do
      extend RailsTrail::ToolRegistration
    end
  end

  it "registers a tool with scope" do
    controller_class.trail_tool :create, scope: :agent
    expect(controller_class._trail_tools).to include(create: hash_including(scope: :agent))
  end

  it "stores an explicit name when provided" do
    controller_class.trail_tool :create, scope: :agent, name: "propose_trade"
    expect(controller_class._trail_tools[:create][:name]).to eq("propose_trade")
  end

  it "stores path and required overrides when provided" do
    controller_class.trail_tool :show, scope: :agent, path: "/api/v1/trades/{trade_id}", required: [:trade_id]
    expect(controller_class._trail_tools[:show]).to include(
      path: "/api/v1/trades/{trade_id}",
      required: [:trade_id]
    )
  end

  it "stores include/exclude params overrides" do
    controller_class.trail_tool :create, scope: :agent, include_params: [:ticker, :side], exclude_params: [:agent_id]
    expect(controller_class._trail_tools[:create]).to include(
      include_params: [:ticker, :side],
      exclude_params: [:agent_id]
    )
  end

  it "accepts query as an array of symbol names" do
    controller_class.trail_tool :index, scope: :agent, query: [:status, :ticker, :limit]
    expect(controller_class._trail_tools[:index][:query]).to eq([:status, :ticker, :limit])
  end

  it "accepts query as a hash with per-param metadata" do
    controller_class.trail_tool :index, scope: :agent, query: {
      status: { type: "string", description: "Filter" },
      limit: { type: "integer" }
    }
    expect(controller_class._trail_tools[:index][:query]).to eq(
      status: { type: "string", description: "Filter" },
      limit: { type: "integer" }
    )
  end

  it "raises if scope is missing" do
    expect { controller_class.trail_tool :create }.to raise_error(ArgumentError, /scope is required/)
  end

  it "raises on invalid scope values" do
    expect { controller_class.trail_tool :create, scope: :operator }.to raise_error(ArgumentError, /scope must be one of/)
  end

  it "inherits registrations to subclasses without mutating the parent" do
    controller_class.trail_tool :index, scope: :agent
    child = Class.new(controller_class)
    child.trail_tool :show, scope: :agent
    expect(child._trail_tools.keys).to contain_exactly(:index, :show)
    expect(controller_class._trail_tools.keys).to contain_exactly(:index)
  end
end
