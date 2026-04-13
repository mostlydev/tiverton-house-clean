require "spec_helper"
require "rails_trail/describe/skill_path_resolver"
require "rails_trail/configuration"
require "tmpdir"
require "fileutils"

RSpec.describe RailsTrail::Describe::SkillPathResolver do
  let(:config) { RailsTrail::Configuration.new }

  around do |example|
    Dir.mktmpdir do |tmpdir|
      @tmpdir = tmpdir
      example.run
    end
  end

  describe "#resolve" do
    it "uses explicit skill_output_path when set" do
      config.skill_output_path = "/custom/path/skill.md"
      resolver = described_class.new(config, rails_root: @tmpdir)
      expect(resolver.resolve).to eq("/custom/path/skill.md")
    end

    it "uses CLAW_POD_ROOT when set" do
      config.service_name = "trading-api"
      resolver = described_class.new(config, rails_root: @tmpdir, env: { "CLAW_POD_ROOT" => "/pod" })
      expect(resolver.resolve).to eq("/pod/services/trading-api/docs/skills/trading-api.md")
    end

    it "detects pod structure from rails_root" do
      pod_root = File.join(@tmpdir, "mypod")
      rails_root = File.join(pod_root, "services", "myapp")
      FileUtils.mkdir_p(rails_root)
      File.write(File.join(pod_root, "claw-pod.yml"), "name: test")

      config.service_name = "myapp"
      resolver = described_class.new(config, rails_root: rails_root, env: {})
      expect(resolver.resolve).to eq(File.join(pod_root, "services", "myapp", "docs", "skills", "myapp.md"))
    end

    it "falls back to rails_root/docs/skills/" do
      config.service_name = "myapp"
      resolver = described_class.new(config, rails_root: @tmpdir, env: {})
      expect(resolver.resolve).to eq(File.join(@tmpdir, "docs", "skills", "myapp.md"))
    end
  end
end
