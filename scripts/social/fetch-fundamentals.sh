#!/bin/bash
# fetch-fundamentals.sh - Fetch fundamentals from Financial Datasets API into ticker metrics store
# Usage: fetch-fundamentals.sh TICKER [--period quarterly|annual|ttm] [--limit N] [--json]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

if command -v uv >/dev/null 2>&1; then
  exec uv run "${SCRIPT_DIR}/fetch-fundamentals.py" "$@"
fi

exec python3 "${SCRIPT_DIR}/fetch-fundamentals.py" "$@"
