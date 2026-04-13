RailsTrail.configure do |config|
  config.service_name = "trading-api"
  config.api_prefix = "/api/v1"

  # LLM config (only used by rails_trail:describe rake task)
  config.ai_model = ENV.fetch("RAILS_TRAIL_AI_MODEL", "claude-sonnet-4-6")
  config.ai_api_key = ENV["ANTHROPIC_API_KEY"]
  config.ai_base_url = ENV.fetch("RAILS_TRAIL_AI_BASE_URL", "https://api.anthropic.com/v1/")

  config.descriptor_output_path = Rails.root.join(".claw-describe.json").to_s
  config.descriptor_description = "Trading desk API — broker connectivity, trade execution, and market context."
  config.descriptor_auth = { type: "bearer", env: "TRADING_API_TOKEN" }
  config.descriptor_skill = "/rails/docs/skills/trade.md"
  config.descriptor_feeds = [
    {
      name: "market-context",
      path: "/api/v1/market_context/{claw_id}",
      ttl: 60,
      description: "Agent-scoped wallet, positions, price motion, and pending orders."
    },
    {
      name: "momentum-context",
      path: "/api/v1/momentum_context/{claw_id}",
      ttl: 60,
      description: "Momentum-ranked watchlist context with relative strength and unusual-volume signals."
    },
    {
      name: "value-context",
      path: "/api/v1/value_context/{claw_id}",
      ttl: 300,
      description: "Value-ranked watchlist context with dividend snapshots, value screens, and beaten-down quality signals."
    },
    {
      name: "desk-risk-context",
      path: "/api/v1/desk_risk_context/{claw_id}",
      ttl: 30,
      description: "Desk-wide trader wallets, positions, pending orders, fills, and risk alerts."
    }
  ]
end
