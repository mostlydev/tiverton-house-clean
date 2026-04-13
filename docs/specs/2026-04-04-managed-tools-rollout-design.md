# Managed Tools Rollout — Design

**Status:** Draft
**Date:** 2026-04-04
**Owner:** Tiverton House desk
**Related:** [RailsTrail design](./2026-03-16-rails-trail-design.md), Clawdapus ADR-017

## Problem

Trader agents interact with `trading-api` by shelling out to repo-local wrapper scripts (`scripts/trade/*.sh`, `scripts/market/*.sh`). Shell invocations are brittle, pollute agent context with stdout/stderr, cost extra turns, and force every agent contract (`trader-base.md`, `approval-workflow.md`) to teach wrapper mechanics.

Clawdapus v0.5.0 shipped **managed tools**: the `cllama` proxy can inject service endpoints as LLM-callable tools, execute them transparently within an inference turn, and return results to the model. The agent no longer needs a shell; the proxy mediates HTTP directly.

This spec defines how Tiverton House adopts managed tools for the trading-api without breaking the script path, and how RailsTrail grows to keep the descriptor in sync with controller code.

## Goals

1. Traders call trading-api endpoints as LLM tools, not via shell wrappers, for the common trading path (reads + trade lifecycle).
2. The `.claw-describe.json` is the authoritative declaration of what trading-api exposes, and stays in sync with controller code automatically.
3. Tool names and schemas are deterministic across builds so `x-claw.tools` allow-lists remain stable.
4. Scripts remain as a fallback for edge cases and operator debugging.

## Non-Goals

- Full replacement of all 60+ API endpoints with tools in phase 1. Reads and the trade lifecycle first; other surfaces come later.
- Auto-deriving policy scopes from Rails code. Role scoping is advisory annotation, not enforcement.
- Deleting wrapper scripts in phase 1.
- LLM involvement in structural descriptor output (tool names, paths, schemas).

## Architecture Overview

Two layers, delivered in phases:

**Infrastructure layer (descriptor + pod wiring):** The trading-api image carries a v2 `.claw-describe.json` that declares tools. Each trader agent subscribes via `x-claw.tools` in `claw-pod.yml`. At `claw up`, clawdapus compiles per-agent `tools.json` manifests consumed by the cllama proxy.

**Generation layer (RailsTrail):** A new `rails_trail:claw_describe` rake task introspects Rails routes, reads `trail_tool` controller annotations, extracts Strong Parameters structure, and emits a deterministic v2 descriptor. This runs during `docker build` so the descriptor ships with the image.

Phase 1 hand-authors the descriptor to unblock traders. Phase 2 replaces hand-authoring with the generator. Phase 3 grows tool coverage as trading-api endpoints are hardened for agent use (e.g. bearer-derived identity).

## Phase 1: Hand-Authored v2 Descriptor + Pod Wiring

### Rewrite `services/trading-api/trading-api.claw-describe.json` to v2

Keep existing `feeds[]` unchanged. Add `auth` block and `tools[]`.

**Auth:**
```json
"auth": {
  "type": "bearer",
  "env": "TRADING_API_TOKEN"
}
```

This tells `claw up` that each consuming agent's `TRADING_API_TOKEN` environment variable is the bearer token. Each trader already has a per-agent token in its pod env (e.g. `WESTON_TRADING_API_TOKEN` → `TRADING_API_TOKEN`), so role scoping at the trading-api principal layer continues to work unchanged.

**Tools — Phase 1 scope (matches committed baseline in `docs/plans/2026-04-03-tool-mediation-rollout.md`):**

Context reads (also served as feeds):
- `get_market_context` — `GET /api/v1/market_context/{claw_id}` (agent-scoped)
- `get_momentum_context` — `GET /api/v1/momentum_context/{claw_id}` (agent-scoped)
- `get_desk_risk_context` — `GET /api/v1/desk_risk_context/{claw_id}` (coordinator)

Read tools:
- `get_positions` — `GET /api/v1/positions` (query: `agent_id`)
- `get_quote` — `GET /api/v1/quotes/{ticker}`
- `get_trade` — `GET /api/v1/trades/{id}`
- `list_trades` — `GET /api/v1/trades` (query: `agent_id`, `status`, `ticker`, `limit`)
- `get_pending_trades` — `GET /api/v1/trades/pending`
- `get_news_latest` — `GET /api/v1/news/latest` (query: `limit`)
- `get_ticker_news` — `GET /api/v1/news/ticker` (query: `symbol`, `days`, `limit`)

Trade lifecycle (scoped at trading-api by principal):
- `propose_trade` — `POST /api/v1/trades` with `body_key: "trade"`
- `confirm_trade` — `POST /api/v1/trades/{id}/confirm`
- `pass_trade` — `POST /api/v1/trades/{id}/pass`
- `cancel_trade` — `POST /api/v1/trades/{id}/cancel`
- `approve_trade` — `POST /api/v1/trades/{id}/approve` (coordinator)
- `deny_trade` — `POST /api/v1/trades/{id}/deny` (coordinator)

Total: 16 tools. Descriptor generator (Phase 2) must produce exactly this set of names so the Phase 1 `x-claw.tools` allow-lists keep working.

Each tool declares:
- `name` — deterministic, lowercase snake_case
- `description` — one or two sentences written for the LLM consumer
- `inputSchema` — JSON Schema (`type: object`, `properties`, `required`). **Flat** — describes the inner fields only. When `body_key` is set, cllama wraps the LLM's flat tool arguments into `{body_key: args}` before POSTing. Do not nest the inner fields under the body key in the schema.
- `http.method`, `http.path` — exact Rails route
- `http.body: "json"` and `http.body_key: "trade"` for the `propose_trade` POST. LLM emits `{ticker, action, quantity, ...}` flat; cllama sends `{"trade": {ticker, action, quantity, ...}}` to Rails. Tested at `clawdapus/cllama@58c02b9`.
- `annotations.readOnly: true` for GET tools
- `annotations.scope: "agent" | "coordinator"` as advisory metadata

Deferred from phase 1 (needs trading-api changes first):
- Watchlist add/remove — currently takes caller-supplied `watchlist.agent_id`, not derived from bearer. Trading-api needs to derive `agent_id` from the principal before these are safe to expose. Tracked as Phase 3 item A.
- Operations endpoints, stop-loss updates, `cleanup_dust`, `revalue` — localhost-only or internal-only.

### Update `claw-pod.yml`

Add pod-level default, overridden per service:

```yaml
x-claw:
  tools-defaults:
    - service: trading-api
      allow:
        - get_market_context
        - get_quote
        - get_trade
        - list_trades
        - get_positions
        - get_news_latest
        - get_ticker_news
```

This gives all agents the shared read baseline from the phase-1 rollout.

Funded traders override to add `propose_trade`, `confirm_trade`, `cancel_trade`, `pass_trade`, and `get_momentum_context`.

Tiverton (coordinator) overrides to add `approve_trade`, `deny_trade`, and `get_desk_risk_context`.

Sentinel can stay on the default read-only set. Allen can add research-specific tools later without changing the trading baseline.

Cllama is already enabled on every agent via `cllama-defaults`, which is a hard prerequisite — declaring `tools:` without cllama is a clawdapus hard error.

### Fix artifact path drift

- `Dockerfile` label `claw.skill.emit=/rails/docs/skills/trade.md` → change to `/rails/docs/skills/trading-api.md` to match `SkillPathResolver.fallback_path`.
- `Dockerfile` label `claw.describe=/trading-api.claw-describe.json` is fragile — the file needs to land at image root. Either `COPY trading-api.claw-describe.json /` during build or change the label to `/rails/trading-api.claw-describe.json` to keep it alongside the Rails app. Prefer the latter.
- Alternatively, use a `LABEL claw.describe=/rails/.claw-describe.json` and `COPY trading-api.claw-describe.json /rails/.claw-describe.json` to match the standard descriptor filename convention.

### Update agent contracts

- `agents/_shared/trader-base.md` — rewrite the "Shared Startup" and "Get your own data" sections so managed tools are the default path; scripts are fallback only. Example: "Use the `get_market_context`, `get_positions`, and `get_quote` tools for reads. Use `propose_trade`, `confirm_trade`, `pass_trade`, and `cancel_trade` for lifecycle. Fall back to `${DESK_SCRIPTS_ROOT}/...` scripts only if the tool is not available."
- `agents/_shared/coordinator-base.md` — same, with coordinator-specific tools (`approve_trade`, `deny_trade`).
- `policy/approval-workflow.md` — replace script references with tool references.
- `agents/_shared/analyst-base.md` — same pattern for Allen's read-heavy tooling.
- `docs/skills/desk-scripts.md` — reframe as "fallback wrapper reference" rather than the primary path.

### Verification

- `claw up -d` — regenerate `compose.generated.yml`, inspect generated `tools.json` under `.claw-runtime/context/<agent>/` to confirm manifest correctness.
- `claw audit --type tool_call --since 1h` — after agents run, verify tool execution traces show up.
- Manual test: exec into a trader's cllama context and issue a chat completion that should trigger `get_market_context` or `get_quote`; confirm the HTTP call lands at trading-api with the agent's bearer.
- Check that `claw up` fails hard if `TRADING_API_TOKEN` is missing from a subscribed agent's env.

## Phase 2: RailsTrail `claw_describe` Generator

### Objective

Replace the hand-authored descriptor with one generated from Rails introspection + controller DSL. Output MUST be deterministic — identical inputs produce identical JSON (stable key ordering, no LLM on structural fields).

### `trail_tool` Controller DSL

```ruby
class Api::V1::TradesController < ApplicationController
  trail_tool :create,    scope: :agent,       name: "propose_trade"
  trail_tool :show,      scope: :agent,       name: "get_trade"
  trail_tool :index,     scope: :agent,       name: "list_trades"
  trail_tool :pending,   scope: :agent,       name: "get_pending_trades"
  trail_tool :approved,  scope: :coordinator, name: "get_approved_trades"
  trail_tool :approve,   scope: :coordinator
  trail_tool :deny,      scope: :coordinator
  trail_tool :cancel,    scope: :agent
  trail_tool :confirm,   scope: :agent
  trail_tool :pass,      scope: :agent
  # execute, fill, fail, stale_proposals, stale_approved — not annotated → not exposed
end
```

**Opt-in semantics.** Only annotated actions become tools. Everything else is silently excluded. This is safer than opt-out and keeps the tool manifest lean.

**DSL fields:**

| Field | Required | Default | Purpose |
|-------|----------|---------|---------|
| `action` (positional) | yes | — | Controller action (`:create`, `:show`, ...) |
| `scope:` | yes | — | `:agent`, `:coordinator`, `:internal` — advisory only, emitted as `annotations.scope` |
| `name:` | no | derived | Explicit tool name; else derived from action + resource |
| `description:` | no | derived | Override description; else a stub is emitted (operator edits the descriptor skill file) |
| `body_key:` | no | auto | Override Strong Params `require(...)` detection |
| `readOnly:` | no | auto | Defaults to `true` for GET, `false` otherwise; emitted as `annotations.readOnly` |

**Name derivation** when `name:` is omitted: `{action}_{resource_singular}` using the route's controller name. Example: `positions#show` → `get_position`; `trades#approve` → `approve_trade`; `trades#index` → `list_trades`. Table-based mapping of CRUD actions to verbs (index → list, show → get, create → create, update → update, destroy → delete). For custom actions (`approve`, `pass`, `confirm`), use the action name as the verb directly.

**Registration:** Class-level attribute `_trail_tools` on `ActionController::API` (or ApplicationController), populated by `trail_tool` calls. Readable by the introspector at describe time.

### Extended Introspector

Today's `Introspector#introspect_routes` produces `{method, path, action}`. Extend it to attach tool metadata when `_trail_tools` has an entry for the action:

```ruby
{
  method: "POST",
  path: "/api/v1/trades",
  action: "api/v1/trades#create",
  tool: {
    name: "propose_trade",
    scope: :agent,
    description: nil,
    body_key: "trade",
    read_only: false,
    input_schema: {
      type: "object",
      properties: {
        ticker:     { type: "string" },
        action:     { type: "string" },
        quantity:   { type: "integer" },
        order_type: { type: "string" }
        # ...
      },
      required: ["ticker", "action", "quantity"]
    }
  }
}
```

`input_schema` is **flat** — it describes the inner fields only. `body_key: "trade"` is emitted as a separate field in the tool's `http` block. cllama does the wrapping at tool-call time (see `clawdapus/cllama@58c02b9`): the LLM emits the flat args, cllama POSTs `{"trade": {...}}` to Rails. Nesting `trade` inside `input_schema` AND setting `body_key: "trade"` would double-wrap to `{"trade": {"trade": {...}}}`, which Rails's `require(:trade)` would read, but the fields would be one level too deep.

**Strong Parameters extraction:** The real mutating controllers delegate `params.require(...).permit(...)` to private helper methods (e.g., `TradesController#create` calls `trade_params` which calls `params.require(:trade).permit(...)`). The introspector must trace from the action to the helper, not scan only the action body. Approach:

1. Parse the controller source with Ruby's `Prism` parser (shipped with Ruby 3.3).
2. Locate the action method by name.
3. Collect called private methods that end in `_params` or are referenced in the action body.
4. Find the definition of those helpers, look for a `params.require(sym).permit(...)` chain.
5. Extract:
   - The `require` argument symbol → `body_key` on `http`, and root of `properties` in `input_schema` is the inner hash (flat, not nested).
   - The `permit` arguments → property names.
   - Type hints from the model class (ActiveRecord column types map to JSON Schema: `string`, `integer`, `number`, `boolean`).
   - Required fields from `validates ..., presence: true` on the model.

When Strong Params use dynamic permit logic (conditional branches, method calls, nested arrays), introspection falls back to `{ "type": "object" }` and logs a warning. For Phase 2 we accept `{type: object}` fallback with warning; Phase 3 promotes persistent warnings to build failures. A DSL `input_schema_override:` field is the escape hatch if needed, deferred until a concrete controller demands it.

**Path parameters:** Extracted from route spec `:id`, `:ticker`, `:agent_id` etc. Emitted as `required` string properties in `input_schema` for GETs, so the LLM provides them explicitly.

**Query parameters:** Declared explicitly via the DSL `query:` option. Two forms accepted:

```ruby
# Shorthand: symbol list, all strings, not required
trail_tool :index, scope: :agent, query: [:agent_id, :status, :ticker, :limit]

# Full form: per-param type/description/required
trail_tool :ticker, scope: :agent, query: {
  symbol: { type: "string", description: "Ticker symbol", required: true },
  days: { type: "integer", description: "Lookback window" },
  limit: { type: "integer" }
}
```

Query params are emitted into `inputSchema.properties`. For GET requests, cllama treats any tool arg not found in the path template as a query parameter. Path params (`{ticker}` in `/api/v1/quotes/{ticker}`) are substituted into the path; everything else is appended as `?key=value`.

**Array-form Strong Params (`tickers: []`):** Rails allows `params.require(:watchlist).permit(:agent_id, :ticker, tickers: [])` to permit an array of primitives. The extractor recognises this and emits the property as `{type: "array", items: {type: "string"}}` in the schema. Nested hashes (`thing: [:a, :b]`) are treated as unresolved in Phase 2.

### New `rails_trail:claw_describe` Rake Task

```ruby
namespace :rails_trail do
  desc "Generate .claw-describe.json v2 from route + DSL introspection"
  task claw_describe: :environment do
    require "rails_trail/describe/claw_descriptor_generator"
    RailsTrail::Describe::ClawDescriptorGenerator.new.generate
  end
end
```

`ClawDescriptorGenerator`:
1. Calls `Introspector#introspect` (extended as above).
2. Builds feed entries from `config.feed_registrations` (existing RailsTrail feed tagging, if present) — for now, these can stay hand-maintained in an initializer and the generator merges them in.
3. Assembles `{ version: 2, description, feeds, tools, auth, skill }`.
4. Writes to `config.descriptor_output_path` (default: `Rails.root.join(".claw-describe.json")`).
5. JSON output uses sorted keys and stable array ordering (tools alphabetical by name) for reproducible builds.

**No LLM call.** The human-facing manual stays in `rails_trail:describe`. The structural descriptor is deterministic Ruby code.

### Descriptor config in the initializer

```ruby
RailsTrail.configure do |config|
  config.service_name = "trading-api"
  config.api_prefix = "/api/v1"
  config.descriptor_output_path = Rails.root.join(".claw-describe.json")
  config.descriptor_auth = { type: "bearer", env: "TRADING_API_TOKEN" }
  config.descriptor_skill = "docs/skills/trading-api.md"
  config.descriptor_description = "Tiverton trading desk API ..."
  config.feeds = [
    { name: "market-context", path: "/api/v1/market_context/{claw_id}", ttl: 60, description: "..." },
    # ...
  ]
end
```

### Dockerfile integration

Add a build step:

```dockerfile
# In the build stage, after COPY . .
RUN bundle exec rake rails_trail:claw_describe

# In the final stage, pull the file alongside the app
# (already covered since we COPY --from=build /rails /rails)
```

Update `LABEL claw.describe=/rails/.claw-describe.json` (or whichever final path we settle on in phase 1).

### Verification

- `bundle exec rake rails_trail:claw_describe` produces output byte-identical to the hand-authored descriptor (after reconciling any intentional differences).
- `rspec gems/rails_trail/spec/describe/claw_descriptor_generator_spec.rb` — fixture app with a stub controller declares `trail_tool`; generator output is diffed against expected JSON.
- `claw up -d` with the generated descriptor reproduces the same `tools.json` manifests as phase 1.
- Build is deterministic: two successive builds produce byte-identical descriptors.

## Phase 3: Expand Coverage

### A. Watchlist tools (after trading-api change)

Today `POST /api/v1/watchlists` requires `watchlist.agent_id` in the body, which lets one agent mutate another's watchlist if they hold the right token. That is safe at the trading-api layer (principal check) but wrong as a tool surface — a compromised or confused LLM could target the wrong agent.

**trading-api change:** `WatchlistsController` derives `agent_id` from `current_api_principal` when the principal is an agent, ignoring any caller-supplied value. Only `internal` principals can target other agents. After that lands, expose:

- `add_to_watchlist` — `POST /api/v1/watchlists`, body `{ tickers: [...] }`
- `remove_from_watchlist` — `DELETE /api/v1/watchlists`, body `{ tickers: [...] }`

### B. Additional tools as hardening lands

Candidates, each gated on its own trading-api review:

- `update_position_stop` (stop-loss edits, currently localhost-only)
- `get_market_context`, `get_momentum_context`, `get_value_context` (GETs; only gate if we want them as tools on top of the feed)
- `get_ticker_metrics`, `get_asset_list` — operational reads
- Research entity reads for Allen

### C. Delete or reduce wrapper scripts

Once tool coverage is comfortable, delete redundant wrappers and keep only the operator-grade debug scripts. Update `desk-scripts.md` to reflect the reduced surface.

## Open Questions

1. **Feed + tool overlap.** `market-context` is both a feed (injected each turn) and could be a tool (called on demand). Do we keep both? Lean: keep feed as ambient context, add tools for targeted deep reads (e.g. `get_quote`, `get_news_ticker`) that wouldn't fit in a feed.

2. **Descriptor filename at image root.** `trading-api.claw-describe.json` vs. canonical `.claw-describe.json`. Clawdapus accepts both via `LABEL claw.describe=<path>`. Recommend `.claw-describe.json` at `/rails/.claw-describe.json` to match convention and make the generator's default path the right one.

3. **Fail-closed vs. degraded mode for schema introspection.** If Strong Params introspection fails on a controller, do we skip the tool or fall back to `{type: object}`? Phase 2 recommendation: fall back + log warning. Phase 3: elevate warnings to build failures once stable.

4. **Phase 1 coordinator-only tools on Tiverton.** Should `approve_trade` / `deny_trade` be on Tiverton exclusively, or also the operator via Leviathan? Current workflow says Tiverton coordinates; keep it that way in phase 1.
