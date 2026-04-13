#!/bin/bash
# db-stale-approved.sh - List APPROVED trades older than threshold (API wrapper)
# Usage: db-stale-approved.sh [--minutes N] [--json] [--notify]
#
# API endpoint: GET /api/v1/trades/stale_approved
# Finds APPROVED records that haven't been executed yet.
# Used by Tiverton during heartbeat to catch stuck approvals.
#
# Options:
#   --minutes N      Threshold in minutes (default: 5)
#   --json           Output as JSON
#   --notify         Send Discord notification (to #infra)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

MINUTES=5
JSON_OUTPUT=0
NOTIFY=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --minutes) MINUTES="$2"; shift 2 ;;
        --json) JSON_OUTPUT=1; shift ;;
        --notify) NOTIFY=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Call API
RESPONSE=$(curl -s -w "\n%{http_code}" -X GET \
    "${API_BASE_URL}/api/v1/trades/stale_approved?minutes=${MINUTES}" 2>&1)

# Extract HTTP status code
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

# Check for curl errors
if [[ $? -ne 0 || -z "$HTTP_CODE" ]]; then
    echo "Error: API unavailable (curl failed)" >&2
    echo "Attempted to connect to: ${API_BASE_URL}/api/v1/trades/stale_approved" >&2
    exit 1
fi

# Handle HTTP responses
if [[ "$HTTP_CODE" != "200" ]]; then
    echo "Error: API request failed (HTTP $HTTP_CODE)" >&2
    echo "$BODY" >&2
    exit 1
fi

# Check if empty
COUNT=$(echo "$BODY" | jq '. | length')

# Format output
if [[ $JSON_OUTPUT -eq 1 ]]; then
    echo "$BODY" | jq '.'
else
    if [[ "$COUNT" == "0" ]]; then
        echo "No stale approvals (threshold: ${MINUTES}m)"
    else
        echo "$BODY" | jq -r '
            ["Agent", "Ticker", "Trade ID", "Side", "Age (min)"],
            ["-----", "------", "--------", "----", "---------"],
            (.[] | [
                .agent_id,
                .ticker,
                .trade_id,
                .side,
                .age_minutes
            ]) | @tsv
        ' | format_tsv_columns

        # Optional Discord notification
        if [[ "$NOTIFY" -eq 1 ]]; then
            MSG="[STALE_APPROVED] $COUNT trades older than ${MINUTES}m

"
            MSG+=$(echo "$BODY" | jq -r '.[] | "\(.trade_id) \(.side) \(.ticker) (\(.age_minutes)m)"')
            notify_discord_channel "${TRADING_INFRA_CHANNEL_ID}" "$MSG" || true
        fi
    fi
fi
