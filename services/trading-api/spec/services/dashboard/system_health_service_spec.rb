# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::SystemHealthService, type: :service do
  describe "#check_gateway" do
    it "does not report a gateway error from inside the containerized runtime" do
      service = described_class.new

      allow(File).to receive(:exist?).with("/.dockerenv").and_return(true)

      result = service.send(:check_gateway)

      expect(result).to eq(name: "Gateway", status: "unknown", message: "Pod-managed")
    end
  end
end
