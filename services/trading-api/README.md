# trading-api Service

This directory is the pod-local vendored Rails app used by both `trading-api` and `sidekiq`.

The pod no longer depends on a sibling `../trading-api` checkout for builds or bootstrap defaults.

Launch model for Monday, March 9, 2026:
- new `trading-api` runtime for the pod
- fresh Postgres database
- separate Redis namespace or instance
- no destructive reset of the current production desk

Pod storage contract expected by the app:
- shared root: `<repo-root>/storage/shared`
- research root: `<repo-root>/storage/shared/research/tickers`
- private root: `<repo-root>/storage/private`

The pod env sets those roots for both `trading-api` and `sidekiq` so dashboard notes and proposal research checks stay aligned with the agent-visible Clawdapus surfaces.

To refresh this vendored copy from another checkout on purpose:

```bash
cd <repo-root>
./scripts/bootstrap/vendor-trading-api.sh --source /path/to/trading-api
```

The sync intentionally excludes `.env*`, `config/master.key`, local storage, and transient logs/tmp state.
