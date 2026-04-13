#!/bin/bash
# db-trade-execute.sh - Execute approved trades via Rails API
# Usage: db-trade-execute.sh [--fill <trade-id> <qty> <price> [--order-id <id>] [--partial] | --fail <trade-id> <reason>]
#
# API endpoints:
#   GET  /api/v1/trades/approved  - Get next approved trade
#   POST /api/v1/trades/:id/execute - Execute trade via Alpaca
#   POST /api/v1/trades/:id/fill - Record fill
#   POST /api/v1/trades/:id/fail - Record failure
#
# Modes:
#   (no args)  Execute next approved trade via API
#   --fill     Record fill for an executing trade
#   --fail     Record failure for an executing trade
#
# Returns: trade details or HEARTBEAT_OK if no work

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"
AUDIT_PUSH_SCRIPT="${TIVERTON_TRADES_ROOT}/update-and-push.sh"

refresh_public_audit_trail() {
    if [[ -x "$AUDIT_PUSH_SCRIPT" ]]; then
        "$AUDIT_PUSH_SCRIPT" &>/dev/null &
    fi
}

# --fill mode: record fill for executing trade
if [[ "$1" == "--fill" ]]; then
    TRADE_ID="${2:?Usage: --fill <trade-id> <qty> <price>}"
    QTY="${3:?Qty required}"
    PRICE="${4:?Price required}"
    ORDER_ID=""
    FINAL=true
    shift 4
    while [[ $# -gt 0 ]]; do
        case $1 in
            --order-id) ORDER_ID="$2"; shift 2 ;;
            --partial) FINAL=false; shift ;;
            *) shift ;;
        esac
    done

    PAYLOAD=$(jq -n \
        --arg qty "$QTY" \
        --arg price "$PRICE" \
        --arg order_id "$ORDER_ID" \
        --argjson final "$FINAL" \
        '{
            qty_filled: ($qty | tonumber),
            avg_fill_price: ($price | tonumber),
            filled_value: (($qty | tonumber) * ($price | tonumber)),
            alpaca_order_id: (if $order_id == "" then null else $order_id end),
            final: $final
        }')

    RESPONSE=$(trading_api_curl_with_status POST "/api/v1/trades/${TRADE_ID}/fill" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" 2>&1 || true)

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | head -n-1)

    if [[ "$HTTP_CODE" == "200" ]]; then
        STATUS=$(echo "$BODY" | jq -r '.status')
        AGENT=$(echo "$BODY" | jq -r '.agent_id')
        TICKER=$(echo "$BODY" | jq -r '.ticker')
        SIDE=$(echo "$BODY" | jq -r '.side')

        if [[ "$STATUS" == "FILLED" ]]; then
            echo "FILLED: $TRADE_ID - $SIDE $QTY $TICKER @ $PRICE"
        else
            echo "Updated: $TRADE_ID - Status: $STATUS"
        fi
        refresh_public_audit_trail
        exit 0
    else
        ERROR=$(echo "$BODY" | jq -r '.error // "Unknown error"')
        echo "Error: $ERROR" >&2
        exit 1
    fi
fi

# --fail mode: record failure for executing trade
if [[ "$1" == "--fail" ]]; then
    TRADE_ID="${2:?Usage: --fail <trade-id> <reason>}"
    REASON="${3:?Reason required}"

    PAYLOAD=$(jq -n --arg reason "$REASON" '{error: $reason}')

    RESPONSE=$(trading_api_curl_with_status POST "/api/v1/trades/${TRADE_ID}/fail" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" 2>&1 || true)

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | head -n-1)

    if [[ "$HTTP_CODE" == "200" ]]; then
        AGENT=$(echo "$BODY" | jq -r '.agent_id')
        TICKER=$(echo "$BODY" | jq -r '.ticker')
        SIDE=$(echo "$BODY" | jq -r '.side')

        echo "FAILED: $TRADE_ID - $REASON"
        refresh_public_audit_trail
        exit 0
    else
        ERROR=$(echo "$BODY" | jq -r '.error // "Unknown error"')
        echo "Error: $ERROR" >&2
        exit 1
    fi
fi

# Default mode: get next approved trade and execute
RESPONSE=$(trading_api_curl_with_status GET "/api/v1/trades/approved" 2>&1 || true)
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [[ "$HTTP_CODE" != "200" ]]; then
    echo "Error: API request failed (HTTP $HTTP_CODE)" >&2
    exit 1
fi

# Check if any trades available
TRADE_COUNT=$(echo "$BODY" | jq 'length')
if [[ "$TRADE_COUNT" == "0" ]]; then
    echo "HEARTBEAT_OK"
    exit 0
fi

# Get first approved trade
TRADE=$(echo "$BODY" | jq '.[0]')
TRADE_ID=$(echo "$TRADE" | jq -r '.trade_id')

echo "Found approved trade: $TRADE_ID"

# Execute via API
EXEC_RESPONSE=$(trading_api_curl_with_status POST "/api/v1/trades/${TRADE_ID}/execute" \
    -H "Content-Type: application/json" \
    -d '{"executed_by": "sentinel"}' 2>&1 || true)

EXEC_HTTP_CODE=$(echo "$EXEC_RESPONSE" | tail -n1)
EXEC_BODY=$(echo "$EXEC_RESPONSE" | head -n-1)

if [[ "$EXEC_HTTP_CODE" == "200" ]]; then
    echo "Execution initiated: $TRADE_ID"
    echo "$EXEC_BODY" | jq '{trade_id, status, ticker, side, qty_filled, avg_fill_price}'
    refresh_public_audit_trail
    exit 0
else
    ERROR=$(echo "$EXEC_BODY" | jq -r '.error // "Execution failed"')
    echo "Error: $ERROR" >&2
    exit 1
fi
