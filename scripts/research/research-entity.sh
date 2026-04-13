#!/usr/bin/env bash
# research-entity.sh - Manage research knowledge graph entities (API wrapper)
# Usage:
#   research-entity.sh list [--type company|person|sector|theme|regulator] [--ticker NVDA]
#   research-entity.sh show <id>
#   research-entity.sh create --name "NVIDIA" --type company [--ticker NVDA] [--summary "..."]
#   research-entity.sh update <id> [--summary "..."] [--last-researched-at now]
#   research-entity.sh graph <id>
#
# API endpoints:
#   GET    /api/v1/research_entities
#   GET    /api/v1/research_entities/:id
#   POST   /api/v1/research_entities
#   PATCH  /api/v1/research_entities/:id
#   GET    /api/v1/research_entities/:id/graph

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

usage() {
    cat <<'EOF'
Usage:
  research-entity.sh list [--type TYPE] [--ticker TICKER]
  research-entity.sh show <id>
  research-entity.sh create --name NAME --type TYPE [--ticker TICKER] [--summary "..."]
  research-entity.sh update <id> [--name NAME] [--summary "..."] [--last-researched-at now]
  research-entity.sh graph <id>

Entity types: company, person, sector, theme, regulator
EOF
}

pretty_json() {
    python3 -m json.tool
}

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 1
fi

COMMAND="$1"; shift

case "$COMMAND" in
    list)
        QUERY=""
        while [[ $# -gt 0 ]]; do
            case $1 in
                --type) QUERY="${QUERY:+${QUERY}&}entity_type=$2"; shift 2 ;;
                --ticker) QUERY="${QUERY:+${QUERY}&}ticker=$2"; shift 2 ;;
                -h|--help) usage; exit 0 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done

        RESPONSE=$(trading_api_curl_with_status GET "/api/v1/research_entities${QUERY:+?${QUERY}}" 2>&1 || true)
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | head -n-1)

        if [[ "$HTTP_CODE" != "200" ]]; then
            echo "Error: API request failed (HTTP ${HTTP_CODE:-unknown})" >&2
            echo "$BODY" >&2
            exit 1
        fi

        printf '%s' "$BODY" | pretty_json
        ;;

    show)
        if [[ $# -lt 1 ]]; then
            echo "Error: show requires an entity ID" >&2
            exit 1
        fi
        ID="$1"; shift

        RESPONSE=$(trading_api_curl_with_status GET "/api/v1/research_entities/${ID}" 2>&1 || true)
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | head -n-1)

        if [[ "$HTTP_CODE" != "200" ]]; then
            echo "Error: API request failed (HTTP ${HTTP_CODE:-unknown})" >&2
            echo "$BODY" >&2
            exit 1
        fi

        printf '%s' "$BODY" | pretty_json
        ;;

    create)
        NAME=""
        TYPE=""
        TICKER=""
        SUMMARY=""

        while [[ $# -gt 0 ]]; do
            case $1 in
                --name) NAME="$2"; shift 2 ;;
                --type) TYPE="$2"; shift 2 ;;
                --ticker) TICKER="$2"; shift 2 ;;
                --summary) SUMMARY="$2"; shift 2 ;;
                -h|--help) usage; exit 0 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done

        if [[ -z "$NAME" || -z "$TYPE" ]]; then
            echo "Error: --name and --type are required" >&2
            exit 1
        fi

        PAYLOAD=$(python3 - "$NAME" "$TYPE" "$TICKER" "$SUMMARY" <<'PY'
import json
import sys

name, entity_type, ticker, summary = sys.argv[1:5]
payload = {
    "research_entity": {
        "name": name,
        "entity_type": entity_type,
    }
}
if ticker:
    payload["research_entity"]["ticker"] = ticker
if summary:
    payload["research_entity"]["summary"] = summary
print(json.dumps(payload))
PY
)

        RESPONSE=$(trading_api_curl_with_status POST "/api/v1/research_entities" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" 2>&1 || true)
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | head -n-1)

        if [[ "$HTTP_CODE" != "201" && "$HTTP_CODE" != "200" ]]; then
            echo "Error: API request failed (HTTP ${HTTP_CODE:-unknown})" >&2
            echo "$BODY" >&2
            exit 1
        fi

        printf '%s' "$BODY" | pretty_json
        ;;

    update)
        if [[ $# -lt 1 ]]; then
            echo "Error: update requires an entity ID" >&2
            exit 1
        fi
        ID="$1"; shift

        NAME=""
        SUMMARY=""
        LAST_RESEARCHED=""

        while [[ $# -gt 0 ]]; do
            case $1 in
                --name) NAME="$2"; shift 2 ;;
                --summary) SUMMARY="$2"; shift 2 ;;
                --last-researched-at) LAST_RESEARCHED="$2"; shift 2 ;;
                -h|--help) usage; exit 0 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done

        PAYLOAD=$(python3 - "$NAME" "$SUMMARY" "$LAST_RESEARCHED" <<'PY'
import json
import sys
from datetime import datetime, timezone

name, summary, last_researched = sys.argv[1:4]
payload = {"research_entity": {}}
if name:
    payload["research_entity"]["name"] = name
if summary:
    payload["research_entity"]["summary"] = summary
if last_researched == "now":
    payload["research_entity"]["last_researched_at"] = datetime.now(timezone.utc).isoformat()
elif last_researched:
    payload["research_entity"]["last_researched_at"] = last_researched
print(json.dumps(payload))
PY
)

        RESPONSE=$(trading_api_curl_with_status PATCH "/api/v1/research_entities/${ID}" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" 2>&1 || true)
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | head -n-1)

        if [[ "$HTTP_CODE" != "200" ]]; then
            echo "Error: API request failed (HTTP ${HTTP_CODE:-unknown})" >&2
            echo "$BODY" >&2
            exit 1
        fi

        printf '%s' "$BODY" | pretty_json
        ;;

    graph)
        if [[ $# -lt 1 ]]; then
            echo "Error: graph requires an entity ID" >&2
            exit 1
        fi
        ID="$1"; shift

        RESPONSE=$(trading_api_curl_with_status GET "/api/v1/research_entities/${ID}/graph" 2>&1 || true)
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | head -n-1)

        if [[ "$HTTP_CODE" != "200" ]]; then
            echo "Error: API request failed (HTTP ${HTTP_CODE:-unknown})" >&2
            echo "$BODY" >&2
            exit 1
        fi

        printf '%s' "$BODY" | pretty_json
        ;;

    -h|--help)
        usage
        exit 0
        ;;

    *)
        echo "Error: Unknown command '$COMMAND'" >&2
        usage >&2
        exit 1
        ;;
esac
