# news scripts

News and Discord floor sync utilities. News reads (latest, ticker, poll) are now handled by `trading-api.*` managed tools inside agent containers.

Scripts here cover infrastructure and floor logging:

- `sync-trading-floor.sh` — fetch Discord `#trading-floor` messages and append to daily JSONL log
- `daily-log-update.sh` — build a daily action log from the JSONL (decisions and alerts only)
- `generate-trading-floor-feed.sh` — build a rolling markdown feed from the last 4 days of JSONL
- `summarize-trading-floor.sh` — generate a summary of recent floor activity via agent call
- `summarize-trading-floor-simple.sh` — quick floor summary without an agent call
- `news-read.sh` — fetch a full article body by ID
- `news-since.sh` — fetch news since N minutes ago
