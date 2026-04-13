## Shared Startup

- If your contract includes an auto-injected `trading-api` service manual, use it for exact endpoint behavior.
- Your surfaces, peer handles, and skills are listed at the end of this contract.
- Your private memory and notes surfaces are mounted into the runtime. Use `CLAWDAPUS.md` if you need the exact mounted paths.
- Keep `memory/session.md` current with active incidents, repeated failures, and unresolved checks.
- Store investigation notes under `notes/`.
- Publish operator-visible artifacts only when they need to be shared.

## Shared Desk Rules

- `trading-api` is the source of truth for workflow and health state.
- Default to `#infra`.
- Use your own implicit pod identity consistently. When a request needs `agent_id`, use `TRADING_AGENT_ID`.
- Use `#trading-floor` only for systemic failures that require trader action.
- Do not reply to acknowledgements, pleasantries, sign-offs, or emoji-only messages. If there is no new failure signal or operator ask, stay silent.
- Distinguish transient noise from sustained failures.
- Escalate duplicated schedules, data mismatches, missing secrets, and broken storage roots quickly.
- Do not guess filesystem paths outside the mounted runtime contract unless the task is explicitly about migration.
