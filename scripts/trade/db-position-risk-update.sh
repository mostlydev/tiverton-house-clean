#!/bin/bash
# db-position-risk-update.sh - Update live stop/target for an open position
# Usage: db-position-risk-update.sh [agent] <ticker> [--stop-loss PRICE] [--target PRICE] [--json]
#
# API endpoints:
#   GET /api/v1/positions?agent_id=<agent>
#   PATCH /api/v1/positions/:id

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

POSITIONAL=()
STOP_LOSS=""
TARGET_PRICE=""
FORMAT="table"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop-loss) STOP_LOSS="$2"; shift 2 ;;
    --target) TARGET_PRICE="$2"; shift 2 ;;
    --json) FORMAT="json"; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ "${#POSITIONAL[@]}" -eq 1 ]]; then
  AGENT="$(require_current_agent_id)"
  TICKER="${POSITIONAL[0]}"
elif [[ "${#POSITIONAL[@]}" -ge 2 ]]; then
  AGENT="${POSITIONAL[0]}"
  TICKER="${POSITIONAL[1]}"
else
  echo "Usage: $0 [agent] <ticker> [--stop-loss PRICE] [--target PRICE] [--json]" >&2
  exit 1
fi

if [[ -z "$STOP_LOSS" && -z "$TARGET_PRICE" ]]; then
  echo "Error: provide --stop-loss and/or --target" >&2
  exit 1
fi

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')

LOOKUP_RESPONSE=$(trading_api_curl_with_status GET "/api/v1/positions?agent_id=${AGENT}" 2>&1 || true)

LOOKUP_HTTP=$(echo "$LOOKUP_RESPONSE" | tail -n1)
LOOKUP_BODY=$(echo "$LOOKUP_RESPONSE" | head -n-1)

if [[ "$LOOKUP_HTTP" != "200" ]]; then
  echo "Error: failed to fetch positions for ${AGENT} (HTTP ${LOOKUP_HTTP})" >&2
  exit 1
fi

POSITION_ID=$(echo "$LOOKUP_BODY" | jq -r --arg t "$TICKER_UPPER" '.positions[]? | select((.ticker | ascii_upcase) == $t) | .id' | head -n1)

if [[ -z "$POSITION_ID" || "$POSITION_ID" == "null" ]]; then
  echo "Error: no open position found for ${AGENT} ${TICKER_UPPER}" >&2
  exit 1
fi

PAYLOAD=$(jq -n \
  --arg stop_loss "$STOP_LOSS" \
  --arg target_price "$TARGET_PRICE" \
  '{
    stop_loss: (if $stop_loss == "" then empty else ($stop_loss | tonumber) end),
    target_price: (if $target_price == "" then empty else ($target_price | tonumber) end)
  }')

# URL-encode position ID to handle special characters (e.g., ETH/USD → ETH%2FUSD)
POSITION_ID_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${POSITION_ID}''', safe=''))")

UPDATE_RESPONSE=$(trading_api_curl_with_status PATCH "/api/v1/positions/${POSITION_ID_ENCODED}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>&1 || true)

UPDATE_HTTP=$(echo "$UPDATE_RESPONSE" | tail -n1)
UPDATE_BODY=$(echo "$UPDATE_RESPONSE" | head -n-1)

if [[ "$UPDATE_HTTP" != "200" ]]; then
  ERROR_MSG=$(echo "$UPDATE_BODY" | jq -r '.error // "unknown error"' 2>/dev/null || echo "unknown error")
  DOCS_HINT=$(echo "$UPDATE_BODY" | jq -r '.docs_hint // empty' 2>/dev/null || true)
  echo "Error: ${ERROR_MSG}" >&2
  if [[ -n "$DOCS_HINT" ]]; then
    echo "$DOCS_HINT" >&2
  fi
  exit 1
fi

if [[ "$FORMAT" == "json" ]]; then
  echo "$UPDATE_BODY" | jq '.'
else
  echo "$UPDATE_BODY" | jq -r '
    "Updated " + .agent_id + " " + .ticker,
    "stop_loss: " + ((.stop_loss // "null") | tostring),
    "target_price: " + ((.target_price // "null") | tostring),
    (.docs_hint // empty)
  '
fi
