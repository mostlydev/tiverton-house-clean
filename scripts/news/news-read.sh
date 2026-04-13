#!/bin/bash
# news-read.sh - Fetch full article body by ID
# Usage: news-read.sh <article-id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

if [[ $# -lt 1 ]]; then
    echo "Usage: news-read.sh <article-id>" >&2
    exit 1
fi

ID="$1"

RESPONSE=$(trading_api_curl_with_status GET "/api/v1/news/${ID}" 2>&1 || true)
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [[ "$HTTP_CODE" != "200" ]]; then
    echo "Error: Failed to fetch article $ID (HTTP ${HTTP_CODE:-unknown})" >&2
    echo "$BODY" >&2
    exit 1
fi

printf '%s' "$BODY" | python3 -c '
import json
import sys

article = json.load(sys.stdin)
symbols = ", ".join(article.get("symbols") or [])
content = article.get("content") or article.get("summary") or "No body available."

print(f"Headline: {article.get('headline') or ''}")
print(f"Source: {article.get('source') or ''}")
print(f"Symbols: {symbols}")
print(f"Published: {article.get('published_at') or ''}")
print(f"URL: {article.get('url') or ''}")
print("")
print(content)
'
