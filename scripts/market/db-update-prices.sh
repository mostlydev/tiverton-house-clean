#!/bin/bash
# db-update-prices.sh - Update position prices from Alpaca (API wrapper)
# Usage: ./db-update-prices.sh [--quiet]
#
# API endpoint: PATCH /api/v1/positions/revalue
# Fetches current prices for all positions and updates current_value in DB
# Run via cron every minute during market hours

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"
QUIET=false

if [[ "$1" == "--quiet" ]]; then
    QUIET=true
fi

log() {
    if [[ "$QUIET" != true ]]; then
        echo "$@"
    fi
}

# Check if market is open (skip weekends and outside hours)
check_market() {
    local HOUR=$(TZ=America/New_York date +%H)
    local DOW=$(TZ=America/New_York date +%u)  # 1=Mon, 7=Sun
    HOUR=$((10#$HOUR))

    # Skip weekends
    if [[ $DOW -ge 6 ]]; then
        log "Market closed (weekend)"
        return 1
    fi

    # Market hours: 9:30 AM - 4:00 PM ET (we check 9-16)
    if [[ $HOUR -lt 9 || $HOUR -ge 16 ]]; then
        log "Market closed (outside hours)"
        return 1
    fi

    return 0
}

# Get unique tickers from positions via API
get_tickers() {
    trading_api_curl GET "/api/v1/positions" | jq -r '.positions[].ticker // empty' | sort -u
}

get_watchlist_tickers() {
    local agents="weston logan dundas"
    local all=""
    for agent in $agents; do
        local response
        response=$(trading_api_curl_with_status GET "/api/v1/watchlists?agent_id=${agent}" 2>/dev/null || true)
        local http_code
        http_code=$(echo "$response" | tail -n1)
        local body
        body=$(echo "$response" | head -n-1)
        if [[ "$http_code" == "200" ]]; then
            all="$all"$'\n'"$(echo "$body" | jq -r '.watchlist[].ticker // empty')"
        fi
    done
    echo "$all" | grep -v '^$' | sort -u
}

# Fetch price from Alpaca
get_price() {
    local TICKER="$1"
    # alpaca price outputs: "SYMBOL: $123.45"
    local OUTPUT=$(alpaca price "$TICKER" 2>/dev/null)
    local PRICE=$(echo "$OUTPUT" | grep -oE '\$[0-9.]+' | tr -d '$')
    echo "$PRICE"
}

# Main
if ! check_market; then
    exit 0
fi

POSITION_TICKERS=$(get_tickers)
WATCHLIST_TICKERS=$(get_watchlist_tickers)
TICKERS=$(printf "%s\n%s\n" "$POSITION_TICKERS" "$WATCHLIST_TICKERS" | grep -v '^$' | sort -u)

if [[ -z "$TICKERS" ]]; then
    log "No tickers to update"
    exit 0
fi

log "Updating prices for: $(echo $TICKERS | tr '\n' ' ')"
log "  Positions: $(echo $POSITION_TICKERS | tr '\n' ' ')"
log "  Watchlist: $(echo $WATCHLIST_TICKERS | tr '\n' ' ')"

# Build prices JSON object
PRICES_JSON="{"
FIRST=true
UPDATED=0
FAILED=0

for TICKER in $TICKERS; do
    PRICE=$(get_price "$TICKER")

    if [[ -n "$PRICE" && "$PRICE" != "null" ]]; then
        if [[ "$FIRST" != true ]]; then
            PRICES_JSON="$PRICES_JSON,"
        fi
        PRICES_JSON="$PRICES_JSON\"$TICKER\":$PRICE"
        FIRST=false

        log "  $TICKER: \$$PRICE"
        UPDATED=$((UPDATED + 1))
    else
        log "  $TICKER: FAILED to get price"
        FAILED=$((FAILED + 1))
    fi
done

PRICES_JSON="$PRICES_JSON}"

# Send to API
if [[ "$UPDATED" -gt 0 ]]; then
    PAYLOAD=$(jq -n --argjson prices "$PRICES_JSON" '{prices: $prices}')

    RESPONSE=$(trading_api_curl_with_status PATCH "/api/v1/positions/revalue" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" 2>&1)

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | head -n-1)

    if [[ $? -ne 0 || -z "$HTTP_CODE" || "$HTTP_CODE" != "200" ]]; then
        log "Error: API unavailable or request failed (HTTP $HTTP_CODE)" >&2
        exit 1
    fi

    API_UPDATED=$(echo "$BODY" | jq -r '.updated')
    log "Updated $API_UPDATED positions via API, $FAILED failed"
else
    log "No prices fetched, skipping API call"
fi
