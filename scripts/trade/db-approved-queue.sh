#!/bin/bash
# db-approved-queue.sh - List approved trades for execution (API wrapper)
# Usage: db-approved-queue.sh [--json]
#
# API endpoint: GET /api/v1/trades/approved
# Shows all trades with status=APPROVED, oldest first

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

FORMAT="table"
if [[ "$1" == "--json" ]]; then
    FORMAT="json"
fi

# Call API
RESPONSE=$(trading_api_curl_with_status GET "/api/v1/trades/approved" 2>&1 || true)

# Extract HTTP status code
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

# Check for curl errors
if [[ $? -ne 0 || -z "$HTTP_CODE" ]]; then
    echo "Error: API unavailable (curl failed)" >&2
    echo "Attempted to connect to: ${API_BASE_URL}/api/v1/trades/approved" >&2
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
if [[ "$COUNT" == "0" ]]; then
    echo "No approved trades in queue"
    exit 0
fi

# Format output
if [[ "$FORMAT" == "json" ]]; then
    echo "$BODY" | jq '.'
else
    echo "=== Approved Queue ($COUNT) ==="
    echo ""
    echo "$BODY" | jq -r '
        ["ID", "Agent", "Ticker", "Side", "Qty", "Amount", "Type", "Approved By", "Approved"],
        ["--", "-----", "------", "----", "---", "------", "----", "-----------", "--------"],
        (.[] | [
            .trade_id,
            .agent_id,
            .ticker,
            .side,
            (.qty_requested // "-"),
            (.amount_requested // "-"),
            .order_type,
            .approved_by,
            (.approved_at | split("T")[0] + " " + (split("T")[1] | split(".")[0] | .[0:5]))
        ]) | @tsv
    ' | format_tsv_columns
fi
