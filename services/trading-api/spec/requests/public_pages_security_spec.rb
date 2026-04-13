# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Public pages security", type: :request do
  describe "GET /notes/:agent/:ticker" do
    before do
      host! "www.tivertonhouse.com"
      allow(Dashboard::AgentNotesService).to receive(:for_agent_ticker).with("weston", "NVDA").and_return(
        {
          content: <<~MARKDOWN,
            # Note

            <script>alert("notes-page-xss-marker")</script>

            [bad](javascript:alert("notes-link-marker"))
          MARKDOWN
          error: nil
        }
      )
    end

    it "serves the public page with a nonce-backed CSP and sanitized markdown" do
      get "/notes/weston/NVDA"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<h1>Note</h1>")
      expect(response.body).not_to include("notes-page-xss-marker")
      expect(response.body).not_to include("notes-link-marker")

      csp = response.headers["Content-Security-Policy"]
      expect(csp).to include("default-src 'self'")
      expect(csp).to include("script-src 'self'")
      expect(csp).to include("style-src 'self' https: 'unsafe-inline'")
      expect(csp).to match(/'nonce-[^']+'/)
      expect(response.body).to include('name="csp-nonce"')
      expect(response.body).to include('nonce="')
    end
  end
end
