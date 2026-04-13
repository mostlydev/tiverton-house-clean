# TODO: Agent Instructions + API Alignment

Goal: ensure trading instructions and the Rails API enforce the same workflow
and guardrails before tomorrow's open.

## Agent instruction updates (DONE)

- Add a required confirmation step before approval. (DONE)
  Implemented API gating for approval/execution on `confirmed_at`, added Leviathan
  confirmation prompts, and updated agent/Tiverton/protocol docs to require
  `CONFIRM <trade-id>` + `db-trade-confirm.sh` after advisory feedback.

- Clarify PROPOSED ownership and flow. (DONE)
  Updated shared + role-specific docs to make agents responsible for
  `db-trade-propose.sh`, with explicit `<@...>` mentions in #trading-floor.

- Document stale approval reconfirmation expectations. (DONE)
  Added reconfirmation templates + 5-minute stale approval nudges; updated
  instructions and stale thresholds across docs and API defaults.

- Explicitly list required thesis tokens for policy exceptions. (DONE)
  Canonical list lives in `<legacy-shared-root>/skills/trade.md`, with references updated to point there.

- Align pre/post‑market rules with actual enforcement. (DONE)
  API rejects pre/after-hours non-LIMIT orders and requires limit_price; CLI help/examples aligned.

## API behavior updates (PARTIAL)

- Enforce confirmation gating in approval or execution. (DONE)
  Approval now blocks without `confirmed_at`, and execution requires confirmation.

- Remove `discord_url` attribute and usage. (DONE)
  Dropped the field, API wiring, and Discord link handling.

-- Add `extended_hours` support (or reject it explicitly). (DONE)
  Added trade-level flag, validation, and Alpaca passthrough.

-- Enforce market‑hours guards for MARKET orders. (DONE)
  Proposal + execution now reject MARKET orders when market is CLOSED.

- Standardize `executed_by` labeling across job and service. (TODO)
  Still pending.

- Add a clear reconfirmation notification template. (DONE)
  Added reconfirm + approval-needed templates that mention the agent and
  instruct `db-trade-confirm.sh`.
