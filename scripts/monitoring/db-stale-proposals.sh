#!/bin/bash
# db-stale-proposals.sh - List PROPOSED trades older than threshold (API wrapper)
# Usage: db-stale-proposals.sh [--minutes N] [--json]
#
# API endpoint: GET /api/v1/trades/stale_proposals
# Finds PROPOSED records that have been sitting without resolution.
# Used by Tiverton during heartbeat to ping agents about abandoned proposals.
#
# Options:
#   --minutes N      Threshold in minutes (default: 5)
#   --json           Output as JSON

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

MINUTES=5
JSON_OUTPUT=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --minutes) MINUTES="$2"; shift 2 ;;
        --json) JSON_OUTPUT=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Call API
RESPONSE=$(curl -s -w "\n%{http_code}" -X GET \
    "${API_BASE_URL}/api/v1/trades/stale_proposals?minutes=${MINUTES}" 2>&1)

# Extract HTTP status code
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

# Check for curl errors
if [[ $? -ne 0 || -z "$HTTP_CODE" ]]; then
    echo "Error: API unavailable (curl failed)" >&2
    echo "Attempted to connect to: ${API_BASE_URL}/api/v1/trades/stale_proposals" >&2
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
        echo "No stale proposals (threshold: ${MINUTES}m)"
    else
        echo "$BODY" | jq -r '
            ["Agent", "Ticker", "Trade ID", "Side", "Urgent", "Age (min)"],
            ["-----", "------", "--------", "----", "------", "---------"],
            (.[] | [
                .agent_id,
                .ticker,
                .trade_id,
                .side,
                (if .is_urgent then "URGENT" else "" end),
                .age_minutes
            ]) | @tsv
        ' | format_tsv_columns
    fi
fi
