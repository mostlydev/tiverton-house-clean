require "spec_helper"

require "json"
require "tmpdir"

require "rails_trail/describe/claw_descriptor_generator"

RSpec.describe RailsTrail::Describe::ClawDescriptorGenerator do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output_path) { File.join(tmpdir, ".claw-describe.json") }

  after { FileUtils.remove_entry(tmpdir) }

  before do
    RailsTrail.configure do |config|
      config.service_name = "test-api"
      config.descriptor_output_path = output_path
      config.descriptor_auth = { type: "bearer", env: "TEST_TOKEN" }
      config.descriptor_skill = "docs/skills/test.md"
      config.descriptor_description = "Test service"
      config.descriptor_feeds = []
    end
  end

  it "writes a v2 descriptor with tools sorted by name" do
    introspector = instance_double(RailsTrail::Describe::Introspector)
    allow(introspector).to receive(:introspect).and_return(
      service_name: "test-api",
      routes: [
        {
          method: "GET",
          path: "/api/v1/trades/:id",
          action: "api/v1/trades#show",
          controller: "api/v1/trades",
          action_name: "show",
          controller_source_path: nil,
          dsl: { scope: :agent }
        },
        {
          method: "GET",
          path: "/api/v1/trades",
          action: "api/v1/trades#index",
          controller: "api/v1/trades",
          action_name: "index",
          controller_source_path: nil,
          dsl: { scope: :agent }
        },
        {
          method: "DELETE",
          path: "/api/v1/trades/:id",
          action: "api/v1/trades#destroy",
          controller: "api/v1/trades",
          action_name: "destroy",
          controller_source_path: nil,
          dsl: nil
        }
      ],
      models: []
    )

    described_class.new(introspector: introspector).generate

    data = JSON.parse(File.read(output_path))
    expect(data["version"]).to eq(2)
    expect(data["auth"]).to eq("type" => "bearer", "env" => "TEST_TOKEN")
    expect(data["skill"]).to eq("docs/skills/test.md")

    tool_names = data["tools"].map { |tool| tool["name"] }
    expect(tool_names).to eq(tool_names.sort)
    expect(tool_names).to contain_exactly("get_trade", "list_trades")
  end
end
