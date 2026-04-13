# RailsTrail Design Spec

## Problem

AI agents operating Rails APIs need two things:

1. **Static understanding** of the API — what endpoints exist, what models do, how state machines progress. Today this is hand-written (e.g., `trade.md`).
2. **Runtime guidance** per response — given this specific model instance in this specific state, what are the concrete next moves? Today this is bespoke per model (e.g., `NextActionService`).

Both are valuable. Neither should require manual maintenance.

## Solution

**RailsTrail** — a Rails gem with two layers:

- **`trail`** (model DSL, runtime, deterministic): Declares or auto-discovers state transitions and emits `next_moves` in API responses.
- **`rails_trail:describe`** (rake task, AI-powered, build time): Introspects routes, models, and trail declarations to generate a markdown skill file describing the API for agent consumption.

## Layer 1: `trail` (Runtime)

### Model DSL

`trail` is added to `ActiveRecord::Base` via Railtie. No `include` needed.

**AASM auto-discovery:**

```ruby
class Trade < ApplicationRecord
  include AASM

  aasm column: :status do
    state :PROPOSED, initial: true
    state :APPROVED
    state :DENIED
    event :approve do
      transitions from: :PROPOSED, to: :APPROVED, guards: [:confirmed_for_approval?]
    end
    event :deny do
      transitions from: :PROPOSED, to: :DENIED
    end
  end

  trail id: :trade_id do
    # Non-AASM actions (field mutations, not state transitions)
    from :PROPOSED, can: [:confirm], if: -> { confirmed_at.blank? },
         description: "Confirm you want to proceed"

    # Only surface these AASM events (hides cancel_from_proposed, etc.)
    expose :approve, :deny, :pass, :cancel
  end
end
```

When `trail` is called on a model that includes AASM:
1. Reads `aasm.events` to get all declared events and their transitions.
2. Filters to events listed in `expose` (if declared). Without `expose`, all AASM events are included.
3. At runtime, for a given instance, determines available moves by checking which events have a transition `from:` matching the current state. **Guards are not executed** — state eligibility is the only AASM check. Guards are an action-time concern (will the transition succeed?), not a display concern (could this action be relevant?).
4. Appends any manual `from` declarations whose state and `if:` conditions match.
5. Resolves each move to a route via `Rails.application.routes`.

**Why guards are not run:** AASM guards may perform queries, have side effects, or raise exceptions. Running them at render time for every response is unsafe and expensive. The `if:` lambdas on manual `from` declarations are the opt-in mechanism for instance-level filtering — they are under the developer's control and expected to be cheap predicates. AASM guards are not.

**Manual declaration (no AASM):**

```ruby
class Order < ApplicationRecord
  trail :status do
    from :pending,    can: [:ship, :cancel]
    from :shipped,    can: [:deliver, :return]
    from :delivered,  can: [:refund], if: -> { delivered_at > 30.days.ago }
  end
end
```

- `trail :column_name` specifies which attribute holds the state.
- `from :state, can: [events]` declares available transitions.
- `if:` accepts a lambda evaluated on the model instance (must be a cheap predicate).
- Optional kwargs: `description:` for agent-readable context.

### AASM Event Name Normalization

AASM models commonly use state-suffixed event names for disambiguation (e.g., `cancel_from_proposed`, `cancel_from_approved`) that all map to a single HTTP endpoint (`POST .../cancel`). The adapter handles this:

1. For each AASM event, strip known suffixes matching `_from_<state>` patterns.
2. The normalized name (e.g., `cancel`) is used for route resolution and the `action` field in `next_moves`.
3. If multiple suffixed events normalize to the same name and are valid from the current state, they are deduplicated into a single move.
4. The `expose` filter matches against **normalized** names: `expose :cancel` covers `cancel`, `cancel_from_proposed`, `cancel_from_approved`, etc.

### Route Resolution

`RailsTrail::RouteMap` introspects `Rails.application.routes` at boot to build a lookup table:

```
{ Trade => { approve: { method: "POST", path_template: "/api/v1/trades/:id/approve" }, ... } }
```

Resolution strategy uses **path-pattern matching**, not Rails resource grouping metadata. This is critical because a single model's routes may be split across multiple `resources` blocks (e.g., read-only routes in one block, mutating routes inside a `constraints` block):

1. Scan all routes matching `config.api_prefix`.
2. For each route, extract the resource name from the path (e.g., `/api/v1/trades/:id/approve` → `trades`).
3. Map resource names to models via Rails conventions (`trades` → `Trade`) or explicit config.
4. Index member actions by their action segment (e.g., `approve`, `deny`).
5. Routes from any `resources` block or `constraints` wrapper are treated identically.

If no route matches a move's action name, the move is included with `path: nil`.

The path template has `:id` replaced with the record's identifier at render time, using the `id:` option from the `trail` declaration (defaults to `:id`).

### Instance Method

`trail` adds `#next_moves` to the model:

```ruby
trade = Trade.find_by(trade_id: "abc-123")
trade.next_moves
# => [
#   { action: "confirm", method: "POST", path: "/api/v1/trades/abc-123/confirm",
#     description: "Confirm you want to proceed" },
#   { action: "pass",    method: "POST", path: "/api/v1/trades/abc-123/pass" },
#   { action: "cancel",  method: "POST", path: "/api/v1/trades/abc-123/cancel" }
# ]
```

Each move is a `RailsTrail::Move` struct with: `action`, `method`, `path`, `description` (optional).

### Controller Concern

```ruby
class Api::V1::TradesController < ApplicationController
  trail_responses
end
```

`trail_responses` is added to `ActionController::Base` via Railtie. It wraps `render json:` to append `next_moves` to responses.

**Detection and injection modes:**

1. **Direct model rendering** (`render json: @trade`): If the object responds to `#next_moves`, serialize the model and merge `next_moves`.
2. **Hash with model** (`render json: { trade: @trade, extra: ... }`): If a hash value responds to `#next_moves`, append to the top-level hash.
3. **Pre-serialized hash with `trail:` option**: For controllers that build response hashes manually (like `trade_json`), pass the source model explicitly:
   ```ruby
   render json: trade_json(trade), trail: trade
   ```
   The concern calls `trade.next_moves` and merges the result into the hash.
4. **Array**: Each element that responds to `#next_moves` gets it appended.

Mode 3 is the **required pattern for the trading-api migration** since it uses `trade_json` helper methods that return plain hashes, not AR instances.

The controller can opt out per-action:

```ruby
def index
  render json: trades, trail: false
end
```

### Response Shape

```json
{
  "trade_id": "abc-123",
  "status": "PROPOSED",
  "confirmed_at": null,
  "next_moves": [
    {
      "action": "confirm",
      "method": "POST",
      "path": "/api/v1/trades/abc-123/confirm",
      "description": "Confirm you want to proceed"
    },
    {
      "action": "pass",
      "method": "POST",
      "path": "/api/v1/trades/abc-123/pass"
    },
    {
      "action": "cancel",
      "method": "POST",
      "path": "/api/v1/trades/abc-123/cancel"
    }
  ]
}
```

## Layer 2: `rails_trail:describe` (Build Time)

### What It Does

A rake task that:
1. Introspects `Rails.application.routes` for all API endpoints.
2. Reads model source files, especially `trail` declarations and AASM state machines.
3. Reads controller source files for parameter handling and response shapes.
4. Sends a structured prompt to an LLM asking it to produce a service manual.
5. Writes the output as a markdown file with YAML frontmatter.

### LLM Provider

Uses `ruby-openai` gem as the sole dependency. Anthropic, OpenAI, Ollama, and any OpenAI-compatible provider work via base URL configuration.

```ruby
# config/initializers/rails_trail.rb
RailsTrail.configure do |config|
  config.service_name = "trading-api"

  # LLM for rake task (not used at runtime)
  config.ai_model = "claude-sonnet-4-6"
  config.ai_api_key = ENV["ANTHROPIC_API_KEY"]
  config.ai_base_url = "https://api.anthropic.com/v1/"
end
```

### Output Path (Pod Awareness)

The skill file path is resolved in order:

1. `config.skill_output_path` if explicitly set.
2. If `ENV['CLAW_POD_ROOT']` is set: `#{CLAW_POD_ROOT}/services/#{service_name}/docs/skills/#{service_name}.md`
3. If the Rails app is under `services/<name>/` in a directory containing `claw-pod.yml`: infer the pod path.
4. Fallback: `#{Rails.root}/docs/skills/#{service_name}.md`

### Output Format

```markdown
---
name: "trading-api"
description: "Auto-generated service manual for the trading-api."
generated_at: "2026-03-16T12:00:00Z"
rails_trail_version: "0.1.0"
---

# trading-api service manual

Base URL: `http://trading-api:4000/api/v1`

## Resources

### Trades
[AI-generated description of what trades are, based on model and controller code]

Endpoints:
- POST /api/v1/trades — Create a proposed trade
- GET /api/v1/trades — List trades
- GET /api/v1/trades/:id — Show trade details
- POST /api/v1/trades/:id/approve — Approve a confirmed trade
[...]

State progression:
  PROPOSED (unconfirmed) -> confirm, pass, cancel (by owner)
  PROPOSED (confirmed)   -> approve, deny (by coordinator)
  APPROVED               -> execute, queue (by system)
  EXECUTING              -> fill, fail (by system)
  Terminal: DENIED, PASSED, CANCELLED, FAILED, FILLED

### Positions
[...]

### Wallets
[...]
```

The AI generates the prose descriptions and organizes the output. The route list, state progressions, and endpoint details come from introspection and are fed to the AI as structured input — the AI narrates, it does not invent.

### Prompt Structure

The rake task builds a prompt with three sections:

1. **Route table** — every route with method, path, controller#action, constraints.
2. **Model declarations** — for each model with `trail`: states, events, transitions, guards, column types. Includes both AASM-discovered and manually declared moves.
3. **Controller source** — parameter handling, before_actions, response patterns.

System prompt instructs the AI to produce a service manual in the skill file format, describing the API for an AI agent that will operate it. The AI is told to describe state progressions as documentation, not to invent transitions beyond what the introspected data shows.

## Configuration

```ruby
# config/initializers/rails_trail.rb
RailsTrail.configure do |config|
  # Identity
  config.service_name = "trading-api"         # defaults to Rails.application.class.module_parent_name.underscore

  # Skill file output
  config.skill_output_path = nil              # explicit override; otherwise auto-resolved

  # LLM (only used by rake task, not runtime)
  config.ai_model = "claude-sonnet-4-6"
  config.ai_api_key = ENV["ANTHROPIC_API_KEY"]
  config.ai_base_url = "https://api.anthropic.com/v1/"

  # Route resolution
  config.api_prefix = "/api/v1"               # scope for route matching; defaults to "/api"
end
```

Per-model ID method (which attribute to substitute for `:id` in paths):

```ruby
trail id: :trade_id   # uses trade.trade_id in path URLs; defaults to :id
```

## Gem Structure

```
rails_trail/
  lib/
    rails_trail.rb                  # configuration, top-level module
    rails_trail/
      railtie.rb                    # adds `trail` to AR::Base, `trail_responses` to AC::Base
      navigable.rb                  # model concern: #next_moves, DSL parsing
      aasm_adapter.rb               # reads AASM declarations, normalizes event names
      route_map.rb                  # path-pattern route introspection, builds lookup table
      move.rb                       # Move struct
      responses.rb                  # controller concern: auto-append next_moves
      describe/
        introspector.rb             # collects routes, models, controllers for prompt
        prompt_builder.rb           # builds LLM prompt from introspected data
        generator.rb                # calls LLM, writes skill file
        skill_path_resolver.rb      # pod-aware output path resolution
  tasks/
    rails_trail.rake                # rails_trail:describe task
  spec/
    trail_spec.rb                   # model DSL unit tests
    aasm_adapter_spec.rb            # AASM introspection + event name normalization tests
    route_map_spec.rb               # path-pattern route resolution tests (split resources blocks)
    responses_spec.rb               # controller concern tests (all 4 detection modes)
    describe/
      introspector_spec.rb
      prompt_builder_spec.rb
      skill_path_resolver_spec.rb
```

## Dependencies

- `ruby-openai` (~> 7.0) — LLM calls for rake task (OpenAI-compatible protocol)
- `rails` (>= 7.0) — Railtie, route introspection, controller concern
- No AASM dependency — adapter is only loaded if AASM is present (`defined?(AASM)`)

## Migration Path for trading-api

To adopt RailsTrail in the existing trading-api:

1. Add `gem 'rails_trail'` to Gemfile.
2. Add `trail` to `Trade` model with required customizations:
   ```ruby
   trail id: :trade_id do
     # confirm is a field mutation, not an AASM event — must be declared manually
     from :PROPOSED, can: [:confirm], if: -> { confirmed_at.blank? },
          description: "Confirm you want to proceed"
     # Only expose the primary AASM events (hides cancel_from_proposed, etc.)
     expose :approve, :deny, :pass, :cancel
   end
   ```
   **Note:** `confirm` sets `confirmed_at` without triggering an AASM transition, so AASM auto-discovery will never surface it. The manual `from` declaration is required.
3. Add `trail_responses` to `Api::V1::TradesController`. Since the controller uses `trade_json` helper methods (returns hashes, not AR instances), each render call must pass the source model explicitly:
   ```ruby
   render json: trade_json(trade), trail: trade
   ```
4. Add initializer with Anthropic config.
5. Run `rails rails_trail:describe` to generate skill file.
6. Compare generated skill file with hand-written `trade.md`; iterate on prompt if needed.
7. Once generated output is good enough, replace `trade.md` with the generated version.
8. Add `rails_trail:describe` to CI or pod build step so skill files stay current.

`NextActionService` and the generated `next_moves` can coexist during migration. The controller can merge both into responses until `NextActionService` is retired.

## Design Decisions

### Why guards are not executed at render time

AASM guards can perform database queries, call external services, or raise exceptions. Executing them for every `next_moves` computation would make JSON rendering unpredictably slow or fragile. Instead, `next_moves` shows what is *structurally possible* from the current state. The agent decides whether to attempt the action; the server enforces guards when the action is actually submitted.

The manual `from` DSL provides `if:` lambdas for cases where instance-level filtering is needed (e.g., `confirmed_at.blank?`). These are under the developer's control and expected to be cheap, side-effect-free predicates.

### Why route resolution uses path-pattern matching

Rails route sets can split a single resource across multiple `resources` blocks (e.g., read routes in one block, write routes inside a `constraints` wrapper). Resource-grouping metadata in the route set does not reliably associate all of a model's routes. Path-pattern matching (`/api/v1/<resource>/:id/<action>`) is more robust and handles this common pattern correctly.

### Why non-AASM actions need manual declaration

Actions that mutate model attributes without triggering AASM transitions (like `confirm` setting `confirmed_at`) are invisible to AASM introspection. This is the most common gap between "what AASM knows" and "what the API exposes." The `from` DSL fills this gap. The migration path must identify these actions for each model.
