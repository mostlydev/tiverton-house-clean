# AGENTS.md

This checkout is the live working tree for the Tiverton trading desk.

`CLAUDE.md` should be a symlink to this file.

## Public Repository

- `mostlydev/tiverton-house-clean` is the public educational snapshot, published as a single sanitized snapshot commit.
- All public-facing links (dashboard, docs) must point to `tiverton-house-clean`, not the private `tiverton-house` repo.
- To update the public snapshot: run `bash scripts/public/publish-snapshot.sh` from `~/tiverton-house-clean` and only use `--push` when you intentionally want to publish.

## Safety

- `.env` contains live API keys — never use `bash -x` or `set -x` on pod scripts, as it prints secrets to stdout.
- When `pod-up.sh` fails, prefer `claw compose build <service> && claw compose up -d <service>` to rebuild individual services.

## How This Repo Relates To The Machine

- `~/tiverton-house`
  - this checkout
  - used for live deploys, runtime inspection, and operational scripts
- `~/tiverton-house-clean`
  - clean Git twin of the same desk repo
  - use it for commits, pushes, and PR work after copying source changes across
- `~/AGENTS.md`
  - host-level operator guidance
- `~/clawdapus`
  - upstream Clawdapus source checkout for product development
  - not the default `claw` binary source for this desk

## Binary And Lifecycle Policy

- Use the installed release `claw` binary from `PATH` by default.
- On Tiverton that should resolve to `~/.local/bin/claw`.
- `./scripts/pod-up.sh` and `./scripts/pod-down.sh` should use that installed release binary unless you explicitly override with `CLAW_BIN`.
- Use `claw update` for normal release upgrades.
- Use `./scripts/bootstrap/install-claw.sh [version]` to bootstrap or pin the official release binary.
- Use `CLAW_BIN=/path/to/dev/claw ...` only when intentionally testing an unreleased Clawdapus build.

## What This Repo Owns

`tiverton-house` is one self-contained Clawdapus trading pod. It owns:

- `claw-pod.yml`
  - live topology, feed subscriptions, agent roster, env wiring, and image wiring
- `agents/`
  - shared contracts, role guides, and per-agent identities
- `scripts/`
  - wrapper scripts agents and operators are expected to use
- `policy/`
  - desk rules and approval boundaries
- `services/trading-api/`
  - the Rails system of record for desk state
- `docs/`
  - conceptual and operator-facing documentation

## Source Of Truth Rules

- `trading-api` is the source of truth for watchlists, positions, wallets, trades, fills, and workflow state.
- `claw-pod.yml` is the source of truth for the live pod shape.
- Agent memory is for notes, follow-ups, and reasoning only.
- Wrapper scripts under `scripts/` are part of the runtime contract; prefer them over handwritten raw API calls.
- `compose.generated.yml` and `.claw-runtime/` are generated output. Inspect them, but do not treat them as source.

## Runtime Layers

### Commit-Worthy Source

- `claw-pod.yml`
- `agents/`
- `scripts/`
- `policy/`
- `docs/`
- `services/trading-api/`

### Generated Runtime Output

- `compose.generated.yml`
- `.claw-runtime/`

### Persistent Local Runtime State

- `.claw-auth/`
- `.claw-memory/`
- `.claw-session-history/`
- `.claw-state/`
- `.claw-backups/`
- `var/` contents
- live `storage/` contents beyond tracked placeholders

## Pod Operations

This is a live trading pod with real money.

Active agents:
- `tiverton`
- `weston`
- `logan`
- `gerrard`
- `dundas`
- `sentinel`

Key services:
- `trading-api`
- `sidekiq`
- `postgres`
- `redis`
- `cllama`
- `claw-api`
- `claw-wall`
- `clawdash`

Normal operator commands:
- `./scripts/verify-pod.sh`
- `./scripts/pod-up.sh`
- `./scripts/pod-down.sh`
- `claw compose ps`
- `claw compose logs <service> --tail N`
- `claw compose exec -T trading-api curl -fsS http://127.0.0.1:4000/up`

## Desk Behavior That Matters

- OpenClaw agents route model traffic through `cllama`.
- Feed injection is provider-owned and role-specific.
- Traders consume trader-scoped market context.
- `tiverton` and `sentinel` consume desk-risk context.
- Discord replies are runtime-routed; agents do not need direct Discord API scripts for normal posting.
- Real cross-agent pings must use explicit Discord IDs in `<@DISCORD_ID>` form.

## Testing

- `rspec` cannot run inside the live `trading-api` container (production mode). Syntax-check with `claw compose exec -T trading-api ruby -c <file>`.
- After code changes, restart with `claw compose restart trading-api` and verify health with the `/up` endpoint.

## Trading-API Key Paths

- `services/trading-api/app/services/trade_proposal_service.rb` — proposal validation guards (all pre-trade checks)
- `services/trading-api/app/services/trades/guard_service.rb` — execution-time validation (market hours, order params)
- `services/trading-api/app/services/trades/remediation_alert_service.rb` — throttled Discord alerts for guard failures
- `services/trading-api/app/controllers/api/v1/trades_controller.rb` — proposal endpoint, failure notifications
- `services/trading-api/config/settings.yml` — all configurable thresholds (env var overridable)
- `services/trading-api/lib/app_config.rb` — typed accessors for settings

## Git Workflow

- Make operational changes here when you need to inspect or validate them live.
- Before committing, copy the source changes you want to keep into `~/tiverton-house-clean`.
- Commit and push from the clean checkout, not from the live runtime tree.
