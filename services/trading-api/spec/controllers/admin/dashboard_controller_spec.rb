# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::DashboardController, type: :controller do
  describe "GET #index" do
    it "returns not found for non-loopback requests" do
      request.host = "www.tivertonhouse.com"
      request.env["REMOTE_ADDR"] = "8.8.8.8"

      get :index

      expect(response).to have_http_status(:not_found)
    end

    it "still challenges loopback requests with basic auth" do
      request.host = "localhost"
      request.env["REMOTE_ADDR"] = "127.0.0.1"

      get :index

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
