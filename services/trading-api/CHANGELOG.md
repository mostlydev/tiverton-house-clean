# Changelog

## [Unreleased]

### Added
- Ledger migration subsystem: ledger entries/transactions/adjustments, reconciliation runs/provenance/diffs, and broker order/fill/account-activity models.
- Outbox infrastructure with events and processing jobs for downstream publishing.
- Trade request tracking for idempotent proposals, including request IDs and normalized payload hashes.
- Ledger and P&L endpoints: `GET /api/v1/agents/:id/realized_pnl` and ledger views for trader dashboards.
- Broker and ledger service layers plus ingestion/reconciliation jobs.
- Operational scripts for backfills, ledger regeneration, and Alpaca fill ingestion.
- Documentation for chart of accounts and P&L workflow integration.

### Changed
- Trade proposal/execution flow now requires confirmation and emits confirmation/reconfirmation notifications.
- Extended-hours trading enforced (limit-only with limit_price and `extended_hours=true`).
- Trade creation returns idempotency metadata (`request_id`, `idempotency_mode`, `idempotent`).
- Stale thresholds adjusted (proposals default 15 minutes; approvals default 5 minutes).
- Positions/wallets/system responses now support ledger-backed projections with `source`/`as_of` markers.
- Fill processing and reconciliation services honor ledger write guards and observe-only modes.
- Trader dashboard UI reworked with updated P&L and ledger summaries.
- README expanded with architecture, glossary, and ledger system details.

### Removed
- Legacy phase/verification progress documents superseded by new migration docs.
