#!/usr/bin/env bash
# research-note.sh - Manage research notes on entities and investigations (API wrapper)
# Usage:
#   research-note.sh list --entity <id>
#   research-note.sh list --investigation <id>
#   research-note.sh create --entity <id> --type finding --content "..."
#   research-note.sh create --investigation <id> --type risk_flag --content "..."
#
# API endpoints:
#   GET    /api/v1/research_notes?notable_type=ResearchEntity&notable_id=:id
#   GET    /api/v1/research_notes?notable_type=Investigation&notable_id=:id
#   POST   /api/v1/research_notes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

usage() {
    cat <<'EOF'
Usage:
  research-note.sh list --entity <id>
  research-note.sh list --investigation <id>
  research-note.sh create --entity <id> --type TYPE --content "..."
  research-note.sh create --investigation <id> --type TYPE --content "..."

Note types: finding, risk_flag, thesis_change, profit_signal, catalyst
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
        ENTITY_ID=""
        INVESTIGATION_ID=""

        while [[ $# -gt 0 ]]; do
            case $1 in
                --entity) ENTITY_ID="$2"; shift 2 ;;
                --investigation) INVESTIGATION_ID="$2"; shift 2 ;;
                -h|--help) usage; exit 0 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done

        if [[ -n "$ENTITY_ID" ]]; then
            API_PATH="/api/v1/research_notes?notable_type=ResearchEntity&notable_id=${ENTITY_ID}"
        elif [[ -n "$INVESTIGATION_ID" ]]; then
            API_PATH="/api/v1/research_notes?notable_type=Investigation&notable_id=${INVESTIGATION_ID}"
        else
            echo "Error: --entity or --investigation is required" >&2
            exit 1
        fi

        RESPONSE=$(trading_api_curl_with_status GET "${API_PATH}" 2>&1 || true)
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
        ENTITY_ID=""
        INVESTIGATION_ID=""
        NOTE_TYPE=""
        CONTENT=""

        while [[ $# -gt 0 ]]; do
            case $1 in
                --entity) ENTITY_ID="$2"; shift 2 ;;
                --investigation) INVESTIGATION_ID="$2"; shift 2 ;;
                --type) NOTE_TYPE="$2"; shift 2 ;;
                --content) CONTENT="$2"; shift 2 ;;
                -h|--help) usage; exit 0 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done

        if [[ -n "$ENTITY_ID" ]]; then
            NOTABLE_TYPE="ResearchEntity"
            NOTABLE_ID="$ENTITY_ID"
        elif [[ -n "$INVESTIGATION_ID" ]]; then
            NOTABLE_TYPE="Investigation"
            NOTABLE_ID="$INVESTIGATION_ID"
        else
            echo "Error: --entity or --investigation is required" >&2
            exit 1
        fi

        if [[ -z "$NOTE_TYPE" || -z "$CONTENT" ]]; then
            echo "Error: --type and --content are required" >&2
            exit 1
        fi

        PAYLOAD=$(python3 - "$NOTABLE_TYPE" "$NOTABLE_ID" "$NOTE_TYPE" "$CONTENT" <<'PY'
import json
import sys

notable_type, notable_id, note_type, content = sys.argv[1:5]
payload = {
    "research_note": {
        "notable_type": notable_type,
        "notable_id": int(notable_id),
        "note_type": note_type,
        "content": content,
    }
}
print(json.dumps(payload))
PY
)

        RESPONSE=$(trading_api_curl_with_status POST "/api/v1/research_notes" \
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
