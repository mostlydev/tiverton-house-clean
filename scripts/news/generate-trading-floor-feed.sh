#!/bin/bash
# generate-trading-floor-feed.sh
# Builds a rolling feed from #trading-floor JSONL logs (last 4 days)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

LOG_DIR="${DESK_LOGS_ROOT}/trading-floor"
FEED_FILE="${DESK_LOGS_ROOT}/trading-floor-feed.md"
WINDOW_DAYS=4

mkdir -p "$LOG_DIR"

NOW_STR=$(date +"%Y-%m-%d %H:%M")

date_minus_days() {
  local days="$1"
  date -d "$days days ago" +%Y-%m-%d 2>/dev/null || date -v-"$days"d +%Y-%m-%d
}

date_plus_one() {
  local day="$1"
  date -d "$day +1 day" +%Y-%m-%d 2>/dev/null || date -v+1d -jf "%Y-%m-%d" "$day" +%Y-%m-%d
}

START_DATE=$(date_minus_days $((WINDOW_DAYS - 1)))
END_DATE=$(date +%Y-%m-%d)

TMP_FILE=$(mktemp)

cat > "$TMP_FILE" <<EOF
## Trading Floor Feed (Last ${WINDOW_DAYS} days)

*Updated: ${NOW_STR}*
EOF

FOUND=0
CURRENT_DATE="$START_DATE"
while true; do
  LOG_FILE="$LOG_DIR/$CURRENT_DATE.jsonl"
  if [[ -f "$LOG_FILE" ]]; then
    FOUND=1
    {
      echo ""
      echo "### $CURRENT_DATE"
      echo ""
      jq -r --arg date "$CURRENT_DATE" '
        def ts_full:
          if .ts_iso then .ts_iso
          elif .ts then ($date + "T" + .ts)
          else "" end;
        if ts_full == "" then empty else
          "- " + (ts_full | gsub("T"; " ")) + " | " +
          (.author // "unknown") + ": " + ((.msg // "") | gsub("\n"; " / "))
        end
      ' "$LOG_FILE"
    } >> "$TMP_FILE"
  fi

  if [[ "$CURRENT_DATE" == "$END_DATE" ]]; then
    break
  fi
  CURRENT_DATE=$(date_plus_one "$CURRENT_DATE")
done

if [[ "$FOUND" -eq 0 ]]; then
  {
    echo ""
    echo "No trading floor activity in the last ${WINDOW_DAYS} days."
  } >> "$TMP_FILE"
fi

mv "$TMP_FILE" "$FEED_FILE"
chmod 444 "$FEED_FILE" || true

echo "Feed generated: $FEED_FILE"
