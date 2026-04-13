#!/bin/bash
# news-since.sh - Fetch news since N minutes ago via Rails API
# Usage: news-since.sh <minutes> [--symbol SYMBOL] [--limit N]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

if [[ $# -lt 1 ]]; then
    echo "Usage: news-since.sh <minutes> [--symbol SYMBOL] [--limit N]" >&2
    exit 1
fi

MINUTES="$1"
shift

SYMBOLS=""
LIMIT=100

while [[ $# -gt 0 ]]; do
    case $1 in
        --symbol|--ticker) SYMBOLS="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

SINCE=$(date -u -d "${MINUTES} minutes ago" +"%Y-%m-%dT%H:%M:%SZ")

QUERY="since=${SINCE}&limit=${LIMIT}"
if [[ -n "$SYMBOLS" ]]; then
    QUERY="${QUERY}&symbols=${SYMBOLS}"
fi

RESPONSE=$(trading_api_curl_with_status GET "/api/v1/news?${QUERY}" 2>&1 || true)
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [[ "$HTTP_CODE" != "200" ]]; then
    echo "Error: Failed to fetch news (HTTP ${HTTP_CODE:-unknown})" >&2
    echo "$BODY" >&2
    exit 1
fi

printf '%s' "$BODY" | python3 -c '
import json
import sys

articles = json.load(sys.stdin) or []
for article in articles:
    published = article.get("published_at") or ""
    headline = article.get("headline") or ""
    source = article.get("source") or ""
    url = article.get("url") or ""
    print(f"- [{published}] {headline} ({source})")
    if url:
        print(f"  {url}")
'
