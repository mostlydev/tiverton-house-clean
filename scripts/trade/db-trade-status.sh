#!/bin/bash
# db-trade-status.sh - Check status of a trade (API wrapper)
# Usage: db-trade-status.sh <trade-id> [--json]
#
# API endpoint: GET /api/v1/trades/:id
# Returns trade details and status

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

# Parse arguments
TRADE_ID="${1:?Usage: $0 <trade-id> [--json]}"
FORMAT="table"

if [[ "$2" == "--json" ]]; then
    FORMAT="json"
fi

# Call API
RESPONSE=$(trading_api_curl_with_status GET "/api/v1/trades/${TRADE_ID}" 2>&1 || true)

# Extract HTTP status code
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

# Check for curl errors
if [[ $? -ne 0 || -z "$HTTP_CODE" ]]; then
    echo "Error: API unavailable (curl failed)" >&2
    echo "Attempted to connect to: ${API_BASE_URL}/api/v1/trades/${TRADE_ID}" >&2
    exit 1
fi

# Handle HTTP responses
if [[ "$HTTP_CODE" == "404" ]]; then
    echo "Error: Trade not found: $TRADE_ID" >&2
    exit 1
elif [[ "$HTTP_CODE" != "200" ]]; then
    echo "Error: API request failed (HTTP $HTTP_CODE)" >&2
    echo "$BODY" >&2
    exit 1
fi

# Format output
if [[ "$FORMAT" == "json" ]]; then
    echo "$BODY" | jq '.'
else
    echo "=== Trade: $TRADE_ID ==="
    echo "$BODY" | jq -r '
        "ID: \(.trade_id)",
        "Agent: \(.agent_id)",
        "Ticker: \(.ticker)",
        "Side: \(.side)",
        "Status: \(.status)",
        "",
        "Order Details:",
        "  Qty Requested: \(.qty_requested // "-")",
        "  Amount Requested: \(.amount_requested // "-")",
        "  Order Type: \(.order_type)",
        "  Limit Price: \(.limit_price // "-")",
        "  Stop Price: \(.stop_price // "-")",
        "",
        "Confirmation:",
        "  Confirmed At: \(.confirmed_at // "-")",
        "  Approved By: \(.approved_by // "-")",
        "  Approved At: \(.approved_at // "-")",
        "",
        "Execution:",
        "  Executed By: \(.executed_by // "-")",
        "  Qty Filled: \(.qty_filled // "-")",
        "  Avg Fill Price: \(.avg_fill_price // "-")",
        "  Execution Completed: \(.execution_completed_at // "-")",
        "",
        "Notes:",
        "  Denial Reason: \(.denial_reason // "-")",
        "  Execution Error: \(.execution_error // "-")"
    '

    # Fetch and display events
    EVENTS_RESPONSE=$(trading_api_curl_with_status GET "/api/v1/trades/${TRADE_ID}/events" 2>&1 || true)

    EVENTS_CODE=$(echo "$EVENTS_RESPONSE" | tail -n1)
    EVENTS_BODY=$(echo "$EVENTS_RESPONSE" | head -n-1)

    if [[ "$EVENTS_CODE" == "200" ]]; then
        echo ""
        echo "Events:"
        echo "$EVENTS_BODY" | jq -r '.events[] | "  \(.event_type) | \(.actor) | \(.created_at)"'
    fi
fi
