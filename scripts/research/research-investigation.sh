#!/usr/bin/env bash
# research-investigation.sh - Manage research investigations (API wrapper)
# Usage:
#   research-investigation.sh list [--status active|paused|completed]
#   research-investigation.sh show <id>
#   research-investigation.sh create --title "AI Chip Supply Chain" [--thesis "..."]
#   research-investigation.sh update <id> [--status completed] [--thesis "..."] [--recommendation "..."]
#   research-investigation.sh entities <id>
#   research-investigation.sh link <investigation_id> <entity_id> --role target
#
# API endpoints:
#   GET    /api/v1/investigations
#   GET    /api/v1/investigations/:id
#   POST   /api/v1/investigations
#   PATCH  /api/v1/investigations/:id
#   GET    /api/v1/investigations/:id/entities
#   POST   /api/v1/investigation_entities

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

usage() {
    cat <<'EOF'
Usage:
  research-investigation.sh list [--status active|paused|completed]
  research-investigation.sh show <id>
  research-investigation.sh create --title TITLE [--thesis "..."]
  research-investigation.sh update <id> [--status STATUS] [--thesis "..."] [--recommendation "..."]
  research-investigation.sh entities <id>
  research-investigation.sh link <investigation_id> <entity_id> --role ROLE

Statuses: active, paused, completed
Roles: target, supplier, customer, competitor, key_person, regulator, adjacent
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
                --status) QUERY="${QUERY:+${QUERY}&}status=$2"; shift 2 ;;
                -h|--help) usage; exit 0 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done

        RESPONSE=$(trading_api_curl_with_status GET "/api/v1/investigations${QUERY:+?${QUERY}}" 2>&1 || true)
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
            echo "Error: show requires an investigation ID" >&2
            exit 1
        fi
        ID="$1"; shift

        RESPONSE=$(trading_api_curl_with_status GET "/api/v1/investigations/${ID}" 2>&1 || true)
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
        TITLE=""
        THESIS=""

        while [[ $# -gt 0 ]]; do
            case $1 in
                --title) TITLE="$2"; shift 2 ;;
                --thesis) THESIS="$2"; shift 2 ;;
                -h|--help) usage; exit 0 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done

        if [[ -z "$TITLE" ]]; then
            echo "Error: --title is required" >&2
            exit 1
        fi

        PAYLOAD=$(python3 - "$TITLE" "$THESIS" <<'PY'
import json
import sys

title = sys.argv[1]
thesis = sys.argv[2]
payload = {"investigation": {"title": title}}
if thesis:
    payload["investigation"]["thesis"] = thesis
print(json.dumps(payload))
PY
)

        RESPONSE=$(trading_api_curl_with_status POST "/api/v1/investigations" \
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
            echo "Error: update requires an investigation ID" >&2
            exit 1
        fi
        ID="$1"; shift

        STATUS=""
        THESIS=""
        RECOMMENDATION=""

        while [[ $# -gt 0 ]]; do
            case $1 in
                --status) STATUS="$2"; shift 2 ;;
                --thesis) THESIS="$2"; shift 2 ;;
                --recommendation) RECOMMENDATION="$2"; shift 2 ;;
                -h|--help) usage; exit 0 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done

        PAYLOAD=$(python3 - "$STATUS" "$THESIS" "$RECOMMENDATION" <<'PY'
import json
import sys

status, thesis, recommendation = sys.argv[1:4]
payload = {"investigation": {}}
if status:
    payload["investigation"]["status"] = status
if thesis:
    payload["investigation"]["thesis"] = thesis
if recommendation:
    payload["investigation"]["recommendation"] = recommendation
print(json.dumps(payload))
PY
)

        RESPONSE=$(trading_api_curl_with_status PATCH "/api/v1/investigations/${ID}" \
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

    entities)
        if [[ $# -lt 1 ]]; then
            echo "Error: entities requires an investigation ID" >&2
            exit 1
        fi
        ID="$1"; shift

        RESPONSE=$(trading_api_curl_with_status GET "/api/v1/investigations/${ID}/entities" 2>&1 || true)
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | head -n-1)

        if [[ "$HTTP_CODE" != "200" ]]; then
            echo "Error: API request failed (HTTP ${HTTP_CODE:-unknown})" >&2
            echo "$BODY" >&2
            exit 1
        fi

        printf '%s' "$BODY" | pretty_json
        ;;

    link)
        if [[ $# -lt 2 ]]; then
            echo "Error: link requires <investigation_id> <entity_id> --role ROLE" >&2
            exit 1
        fi
        INVESTIGATION_ID="$1"; shift
        ENTITY_ID="$1"; shift

        ROLE=""
        while [[ $# -gt 0 ]]; do
            case $1 in
                --role) ROLE="$2"; shift 2 ;;
                -h|--help) usage; exit 0 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done

        if [[ -z "$ROLE" ]]; then
            echo "Error: --role is required" >&2
            exit 1
        fi

        PAYLOAD=$(python3 - "$INVESTIGATION_ID" "$ENTITY_ID" "$ROLE" <<'PY'
import json
import sys

investigation_id, entity_id, role = sys.argv[1:4]
payload = {
    "investigation_entity": {
        "investigation_id": int(investigation_id),
        "research_entity_id": int(entity_id),
        "role": role,
    }
}
print(json.dumps(payload))
PY
)

        RESPONSE=$(trading_api_curl_with_status POST "/api/v1/investigation_entities" \
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
