# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  describe "#format_discord_mentions" do
    it "escapes untrusted html while preserving known mention styling" do
      allow(helper).to receive(:discord_users).and_return({ "12345" => "weston<script>" })

      rendered = helper.format_discord_mentions("Heads up <@12345>\n<img src=x onerror=alert(1)>")

      expect(rendered).to include('<span class="mention">@weston&lt;script&gt;</span>')
      expect(rendered).to include("&lt;img src=x onerror=alert(1)&gt;")
      expect(rendered).not_to include("<img")
    end
  end

  describe "#markdown" do
    it "keeps safe markdown formatting and strips active content" do
      rendered = helper.markdown(<<~MARKDOWN)
        # Conviction

        <script>alert("note-xss-marker")</script>

        [bad link](javascript:alert("bad-link-marker"))

        [good link](https://example.com/research)
      MARKDOWN

      expect(rendered).to include("<h1>Conviction</h1>")
      expect(rendered).to include('href="https://example.com/research"')
      expect(rendered).to include('target="_blank"')
      expect(rendered).to include('rel="noopener noreferrer"')
      expect(rendered).not_to include("note-xss-marker")
      expect(rendered).not_to include("javascript:alert")
      expect(rendered).not_to include("bad-link-marker")
    end
  end
end
