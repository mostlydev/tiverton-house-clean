#!/bin/bash
# db-wallet-get.sh - Get wallet state for an agent (API wrapper)
# Usage: db-wallet-get.sh [agent] [--json | --all]
#
# API endpoints: GET /api/v1/wallets (all) or GET /api/v1/wallets/:agent_id (specific)
#
# Options:
#   --json    Output as JSON
#   --all     Show all trading agents

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

AGENT=""
FORMAT="table"
ALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --json) FORMAT="json"; shift ;;
        --all) ALL=true; shift ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) AGENT="$1"; shift ;;
    esac
done

if [[ "$ALL" != true && -z "$AGENT" ]]; then
    AGENT="$(pod_current_agent_id 2>/dev/null || true)"
fi

if [[ "$ALL" == true || -z "$AGENT" ]]; then
    # Get all wallets
    RESPONSE=$(trading_api_curl_with_status GET "/api/v1/wallets" 2>&1 || true)

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | head -n-1)

    if [[ $? -ne 0 || -z "$HTTP_CODE" || "$HTTP_CODE" != "200" ]]; then
        echo "Error: API unavailable or request failed (HTTP $HTTP_CODE)" >&2
        exit 1
    fi

    # Handle both formats: {wallets: [...]} or direct [...]
    WALLETS=$(echo "$BODY" | jq 'if type == "object" and has("wallets") then .wallets else . end')

    if [[ "$FORMAT" == "json" ]]; then
        echo "$BODY" | jq '.'
    else
        echo "=== Trading Wallets ==="
        echo "$WALLETS" | jq -r '
            ["Agent", "Wallet", "Cash", "Invested", "Util%"],
            ["-----", "------", "----", "--------", "-----"],
            (.[] | [
                .agent_id,
                (.wallet_size | tonumber | round),
                (.cash | tonumber | round),
                (.invested | tonumber | round),
                (if .allocation_percentage then (.allocation_percentage | tonumber | round)
                 elif (.wallet_size | tonumber) > 0 then (((.invested | tonumber) / (.wallet_size | tonumber) * 100) | round)
                 else 0 end)
            ]) | @tsv
        ' | format_tsv_columns

        echo ""
        TOTAL=$(echo "$WALLETS" | jq '[.[] | .invested | tonumber] | add | round')
        echo "Total deployed: \$$TOTAL"
    fi
else
    # Get specific agent wallet
    RESPONSE=$(trading_api_curl_with_status GET "/api/v1/wallets/${AGENT}" 2>&1 || true)

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | head -n-1)

    if [[ $? -ne 0 || -z "$HTTP_CODE" ]]; then
        echo "Error: API unavailable" >&2
        exit 1
    fi

    if [[ "$HTTP_CODE" == "404" ]]; then
        echo "Error: Agent not found: $AGENT" >&2
        exit 1
    elif [[ "$HTTP_CODE" != "200" ]]; then
        echo "Error: API request failed (HTTP $HTTP_CODE)" >&2
        exit 1
    fi

    if [[ "$FORMAT" == "json" ]]; then
        echo "$BODY" | jq '.'
    else
        echo "=== Wallet: $AGENT ==="
        echo "$BODY" | jq -r '
            ["Wallet", "Cash", "Invested", "Util%"],
            ["------", "----", "--------", "-----"],
            ([
                (.wallet_size | tonumber | round),
                (.cash | tonumber | round),
                (.invested | tonumber | round),
                (if .allocation_percentage then (.allocation_percentage | tonumber | round)
                 elif (.wallet_size | tonumber) > 0 then (((.invested | tonumber) / (.wallet_size | tonumber) * 100) | round)
                 else 0 end)
            ]) | @tsv
        ' | format_tsv_columns
    fi
fi
