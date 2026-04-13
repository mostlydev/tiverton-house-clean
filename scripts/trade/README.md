# trade scripts

Operator-facing wrappers for trade and wallet state. Trade lifecycle actions (propose, confirm, approve, deny, pass, cancel) and position/watchlist reads are now handled by `trading-api.*` managed tools inside agent containers.

Scripts here cover the remaining operator and infrastructure surface:

- `db-wallet-get.sh` — inspect wallet state from the host
- `db-trade-status.sh` — check trade status from the host
- `db-trade-execute.sh` — fill or fail a trade (broker execution)
- `db-approved-queue.sh` — list approved trades awaiting execution
- `db-position-risk-update.sh` — update stop/target on an open position
