require "spec_helper"

require "rails_trail/describe/strong_params_extractor"

RSpec.describe RailsTrail::Describe::StrongParamsExtractor do
  let(:fixtures_dir) { File.expand_path("../fixtures/controllers", __dir__) }

  def extract(filename, action)
    source = File.read(File.join(fixtures_dir, filename))
    described_class.new(source: source).extract(action: action)
  end

  describe "helper method resolution" do
    it "follows a *_params helper via require.permit" do
      result = extract("simple_controller.rb", :create)
      expect(result[:body_key]).to eq(:thing)
      expect(result[:properties]).to contain_exactly(:name, :color, :qty)
      expect(result[:array_properties]).to eq({})
      expect(result[:unresolved]).to be(false)
    end

    it "returns empty properties for actions with no write params" do
      result = extract("simple_controller.rb", :show)
      expect(result[:body_key]).to be_nil
      expect(result[:properties]).to eq([])
      expect(result[:array_properties]).to eq({})
      expect(result[:unresolved]).to be(false)
    end
  end

  describe "inline permit calls in the action body" do
    it "extracts require.permit directly from the action" do
      result = extract("inline_controller.rb", :create)
      expect(result[:body_key]).to eq(:thing)
      expect(result[:properties]).to contain_exactly(:name, :color)
      expect(result[:array_properties]).to eq({})
      expect(result[:unresolved]).to be(false)
    end
  end

  describe "dynamic permit logic" do
    it "marks extractions unresolved when permit args are dynamic" do
      result = extract("dynamic_controller.rb", :create)
      expect(result[:unresolved]).to be(true)
    end
  end

  describe "array-form permit arguments" do
    it "treats tickers: [] as an array-of-strings property" do
      result = extract("array_permit_controller.rb", :create)
      expect(result[:body_key]).to eq(:watchlist)
      expect(result[:properties]).to contain_exactly(:agent_id, :ticker, :tickers)
      expect(result[:array_properties]).to eq(tickers: "string")
      expect(result[:unresolved]).to be(false)
    end
  end

  describe "params.permit without require" do
    it "returns no body_key but lists properties" do
      result = extract("no_require_controller.rb", :create)
      expect(result[:body_key]).to be_nil
      expect(result[:properties]).to contain_exactly(:name, :color)
      expect(result[:unresolved]).to be(false)
    end
  end

  describe "missing action" do
    it "raises ArgumentError" do
      expect { extract("simple_controller.rb", :nonexistent) }.to raise_error(ArgumentError, /nonexistent/)
    end
  end
end
