# Repository Guidelines

## Project Structure & Module Organization
- `app/` contains Rails code: `models/`, `controllers/`, `services/`, `jobs/`, and `channels/`.
- `spec/` holds RSpec tests by area (`models/`, `services/`, `integration/`) with factories in `spec/factories/`.
- `config/`, `db/`, and `lib/` contain Rails configuration, migrations, and shared utilities.
- `bin/` includes project scripts (e.g., `bin/rails`, `bin/rubocop`).

## Build, Test, and Development Commands
- `bundle install` — install Ruby gems.
- `sg docker -c "docker-compose up -d"` — start PostgreSQL + Redis containers.
- `bin/rails db:create` / `bin/rails db:migrate` — create and migrate databases.
- `bin/rails server -p 4000` — run the API server locally on port 4000.
- `bundle exec sidekiq -C config/sidekiq.yml` — run background jobs.
- `bundle exec rspec` — run all tests.
- `bin/rubocop` — run linting with the Omakase Rails style.

## Coding Style & Naming Conventions
- Ruby/Rails style with 2-space indentation.
- Class/module names use `CamelCase`; files, methods, and variables use `snake_case`.
- Linting is configured via `.rubocop.yml` (inherits `rubocop-rails-omakase`).

## Testing Guidelines
- RSpec is the test framework; tests live under `spec/` and follow `*_spec.rb` naming.
- Use factories in `spec/factories/` for test data.
- No explicit coverage threshold is enforced; keep tests focused on API endpoints, models, and services.

## Commit & Pull Request Guidelines
- Use short, descriptive subjects; recent commits often follow an `Area: description` pattern (e.g., `Phase 1: ...`, `Memory: ...`).
- PRs should include: a concise summary, key files touched, and how you verified changes (`bundle exec rspec`, manual API checks, etc.).
- Add screenshots only if you modify any UI views in `app/views/`.

## Ticker Metrics & Social Sentiment
- `TickerMetric` stores time-series metrics per ticker (social mentions, fundamentals, valuation, growth, health).
- Config: `config/ticker_metrics.yml` defines TTLs, refresh rate limits, and human-readable labels for all metrics.
- `TickerMetricsRefreshService` orchestrates on-demand refresh via Sidekiq, routing to the correct fetcher (ApeWisdom for `social_mentions_*`, fundamentals for `fs_*`/`val_*`/etc.).
- `Api::V1::TickerDiscoverabilityController` — `GET /api/v1/ticker_discoverability` ranks tickers by a given metric (default: `social_mentions_24h`, source: `apewisdom`). Supports `only_holdings`, `limit`, `include_stale` params.
- `Api::V1::TickerMetricsController` — `GET /api/v1/ticker_metrics` (read), `POST /api/v1/ticker_metrics/bulk` (write, used by external fetcher scripts).
- External fetcher scripts now primarily live in the pod repo under `scripts/social/`.

## Pod Storage Paths
- Prefer env-driven roots over hardcoded local paths.
- Shared research should resolve from `DESK_RESEARCH_ROOT`.
- Agent memory and notes should resolve from `DESK_PRIVATE_ROOT`.
- Watchlists and positions are API-owned state, not markdown files under agent memory.

## Configuration & Security Notes
- Copy `.env.example` to `.env` and keep secrets out of git.
- Local services assume PostgreSQL 16 and Redis 7 via Docker.

## RailsTrail Descriptor Contract
- Managed tools are declared with `trail_tool` on controllers and compiled into `.claw-describe.json` by `bundle exec rake rails_trail:claw_describe`.
- Build-time descriptor generation must not require a live database; schema typing should fall back to `db/schema.rb` when ActiveRecord cannot connect.
- Prefer explicit `name:`, `description:`, and `required:` when the external tool contract differs from raw Strong Params or model validations.
- Use `path:` when the public tool path must differ from the Rails route placeholder, for example `{claw_id}` or `{trade_id}`.
- Use `include_params:` or `exclude_params:` when the externally exposed schema should not mirror every permitted controller field.
- Keep `query:` metadata explicit for GET-style tools so the generated schema matches the intended agent-facing contract.
