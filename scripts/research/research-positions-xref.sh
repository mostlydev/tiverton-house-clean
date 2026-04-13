#!/usr/bin/env bash
# research-positions-xref.sh - Cross-reference research entities against held positions
# Usage: research-positions-xref.sh [--json]
#
# Fetches all positions and all company-type research entities,
# matches by ticker, and prints which research entities correspond
# to held positions (and which positions lack research coverage).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

FORMAT="table"
while [[ $# -gt 0 ]]; do
    case $1 in
        --json) FORMAT="json"; shift ;;
        -h|--help)
            echo "Usage: research-positions-xref.sh [--json]"
            echo "Cross-reference research entities against held positions."
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required" >&2
    exit 1
fi

# Fetch all positions
POS_RESPONSE=$(trading_api_curl_with_status GET "/api/v1/positions" 2>&1 || true)
POS_HTTP=$(echo "$POS_RESPONSE" | tail -n1)
POS_BODY=$(echo "$POS_RESPONSE" | head -n-1)

if [[ "$POS_HTTP" != "200" ]]; then
    echo "Error: Failed to fetch positions (HTTP ${POS_HTTP:-unknown})" >&2
    exit 1
fi

# Fetch all company entities
ENT_RESPONSE=$(trading_api_curl_with_status GET "/api/v1/research_entities?entity_type=company" 2>&1 || true)
ENT_HTTP=$(echo "$ENT_RESPONSE" | tail -n1)
ENT_BODY=$(echo "$ENT_RESPONSE" | head -n-1)

if [[ "$ENT_HTTP" != "200" ]]; then
    echo "Error: Failed to fetch research entities (HTTP ${ENT_HTTP:-unknown})" >&2
    exit 1
fi

POS_FILE=$(mktemp)
ENT_FILE=$(mktemp)
trap 'rm -f "$POS_FILE" "$ENT_FILE"' EXIT
printf '%s' "$POS_BODY" > "$POS_FILE"
printf '%s' "$ENT_BODY" > "$ENT_FILE"

python3 - "$FORMAT" "$POS_FILE" "$ENT_FILE" <<'PY'
import json
import sys


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def normalize_positions(payload):
    if isinstance(payload, dict) and "positions" in payload:
        return payload["positions"] or []
    if isinstance(payload, list):
        return payload
    return []


def normalize_entities(payload):
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        if "research_entities" in payload:
            return payload["research_entities"] or []
        if "entities" in payload:
            return payload["entities"] or []
    return []


def ticker_key(value):
    return (value or "").upper()


def print_table(rows):
    widths = [max(len(row[idx]) for row in rows) for idx in range(len(rows[0]))]
    for row in rows:
        print("  ".join(cell.ljust(widths[idx]) for idx, cell in enumerate(row)))


fmt, positions_path, entities_path = sys.argv[1:4]
positions = normalize_positions(load_json(positions_path))
entities = normalize_entities(load_json(entities_path))
entity_map = {ticker_key(entity.get("ticker")): entity for entity in entities if ticker_key(entity.get("ticker"))}
held_tickers = {ticker_key(position.get("ticker")) for position in positions}

covered = []
uncovered = []
for position in positions:
    ticker = ticker_key(position.get("ticker"))
    entity = entity_map.get(ticker)
    if entity:
        covered.append(
            {
                "ticker": position.get("ticker"),
                "agent_id": position.get("agent_id"),
                "qty": position.get("qty"),
                "entity_id": entity.get("id"),
                "entity_name": entity.get("name"),
                "last_researched_at": entity.get("last_researched_at"),
            }
        )
    else:
        uncovered.append(
            {
                "ticker": position.get("ticker"),
                "agent_id": position.get("agent_id"),
                "qty": position.get("qty"),
            }
        )

unmatched_entities = [
    {
        "id": entity.get("id"),
        "name": entity.get("name"),
        "ticker": entity.get("ticker"),
    }
    for entity in entities
    if ticker_key(entity.get("ticker")) not in held_tickers
]

if fmt == "json":
    print(
        json.dumps(
            {
                "covered": covered,
                "uncovered": uncovered,
                "unmatched_entities": unmatched_entities,
            },
            indent=2,
        )
    )
    raise SystemExit(0)

print("=== Research Coverage: Held Positions ===")
print("")

if covered:
    print(f"Covered ({len(covered)}):")
    rows = [["Ticker", "Agent", "Entity", "Last Researched"], ["------", "-----", "------", "----------------"]]
    for item in covered:
        rows.append(
            [
                str(item.get("ticker") or ""),
                str(item.get("agent_id") or ""),
                str(item.get("entity_name") or ""),
                str(item.get("last_researched_at") or "never"),
            ]
        )
    print_table(rows)
    print("")

if uncovered:
    print(f"No research entity ({len(uncovered)}):")
    for item in uncovered:
        print(f"  {item.get('ticker', '')} ({item.get('agent_id', '')})")
    print("")

print(f"Coverage: {len(covered)}/{len(positions)} positions have research entities")
PY
