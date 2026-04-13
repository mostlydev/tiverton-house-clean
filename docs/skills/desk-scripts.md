---
name: "desk-scripts"
description: "Discoverable map of the repo-local wrapper scripts mounted into agent containers."
---

# desk script surface

> Managed tools are the preferred path for trade workflow, common reads, and watchlist management. This reference documents the wrapper scripts as a fallback for operator debugging and as coverage for surfaces that still do not have tools (research-specific flows, audit export).

Use `DESK_SCRIPTS_ROOT` when it is set. If it is unset, read `CLAWDAPUS.md` and use the mounted scripts path listed there.
This skill exists so agents can discover the wrapper surface from configuration instead of assuming a `/workspace` symlink.

## Stable directories

- `${DESK_SCRIPTS_ROOT}/trade/` for trade workflow, wallet and position reads, and watchlist management.
- `${DESK_SCRIPTS_ROOT}/market/` for market context, quotes, and price refresh helpers.
- `${DESK_SCRIPTS_ROOT}/news/` for latest-news and ticker-news reads.
- `${DESK_SCRIPTS_ROOT}/monitoring/` for readiness, stale-state, and broker consistency checks.
- `${DESK_SCRIPTS_ROOT}/audit/` for desk audit export.
- `${DESK_SCRIPTS_ROOT}/bootstrap/` for pod setup and rendering utilities, not routine trading actions.

## High-frequency commands

Wallet:

```bash
"${DESK_SCRIPTS_ROOT:-<repo-root>/scripts}/trade/db-wallet-get.sh" --json
```

Positions:

```bash
"${DESK_SCRIPTS_ROOT:-<repo-root>/scripts}/trade/db-positions-get.sh" --json
```

Watchlist:

```bash
"${DESK_SCRIPTS_ROOT:-<repo-root>/scripts}/trade/db-watchlist.sh" list --json
"${DESK_SCRIPTS_ROOT:-<repo-root>/scripts}/trade/db-watchlist.sh" add AAPL NVDA TSLA
"${DESK_SCRIPTS_ROOT:-<repo-root>/scripts}/trade/db-watchlist.sh" remove AAPL
```

Trade status:

```bash
"${DESK_SCRIPTS_ROOT:-<repo-root>/scripts}/trade/db-trade-status.sh" <trade-id> --json
```

Market context:

```bash
"${DESK_SCRIPTS_ROOT:-<repo-root>/scripts}/market/market-context.sh"
```

Ticker news:

```bash
"${DESK_SCRIPTS_ROOT:-<repo-root>/scripts}/news/news-ticker.sh" AAPL
```

## Watchlist notes

- `db-watchlist.sh` is the correct wrapper for watchlist management.
- Watchlists live in `trading-api`, not in `memory/watchlist.md`.
- The direct API result updates immediately, but injected market context refreshes on its own schedule.
- If newly added names do not appear in context yet, verify the live API state with `db-watchlist.sh list --json`.
- Use `--agent <id>` only when the task explicitly requires acting on or inspecting another agent.

## Working rules

- Prefer these wrappers over raw `curl`.
- Use the auto-injected `trading-api` manual for full trade-workflow semantics and exact argument requirements.
- Use `--json` whenever you need machine-readable output.
