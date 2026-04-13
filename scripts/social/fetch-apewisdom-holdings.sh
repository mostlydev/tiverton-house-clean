#!/bin/bash
# fetch-apewisdom-holdings.sh - Fetch ApeWisdom mentions for portfolio tickers
# Usage: fetch-apewisdom-holdings.sh [--subreddit wallstreetbets] [--window 1h|24h] [--limit N] [--filter all-stocks|all-crypto] [--json]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

if command -v uv >/dev/null 2>&1; then
  exec uv run "${SCRIPT_DIR}/fetch-apewisdom.py" --holdings "$@"
fi

exec python3 "${SCRIPT_DIR}/fetch-apewisdom.py" --holdings "$@"
