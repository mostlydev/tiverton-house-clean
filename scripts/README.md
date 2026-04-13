# scripts

Operator and infrastructure scripts for the pod. Trade lifecycle, position reads, watchlist management, and news queries are handled by `trading-api.*` managed tools inside agent containers — not these scripts.

- `trade/` — operator-facing wallet, trade status, execution, and position risk wrappers
- `market/` — price update utilities
- `news/` — Discord floor sync, log generation, and article read helpers
- `monitoring/` — readiness checks, broker reconciliation, stale-state detection, agent healthchecks
- `audit/` — desk audit export
- `bootstrap/` — pod setup, rendering, vendoring, and init utilities
- `lib/` — shared env and shell helpers
- `social/` — external data fetchers (ApeWisdom, fundamentals)
