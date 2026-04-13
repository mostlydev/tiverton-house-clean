#!/bin/bash
# daily-log-update.sh
# Builds a daily action log from #trading-floor JSONL (decisions/alerts only)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

DATE=$(date +%Y-%m-%d)
LOG_DIR="${DESK_LOGS_ROOT}/trading-floor"
LOG_FILE="$LOG_DIR/$DATE.jsonl"
STATE_FILE="$LOG_DIR/.daily-log-state"
DAILY_LOG="${DESK_SHARED_ROOT}/daily-log-$DATE.md"

mkdir -p "$LOG_DIR"

# Initialize state if missing
if [[ ! -f "$STATE_FILE" ]]; then
  echo "$DATE|0" > "$STATE_FILE"
fi

LAST_DATE=$(cut -d'|' -f1 "$STATE_FILE")
LAST_LINE=$(cut -d'|' -f2 "$STATE_FILE")
if [[ "$LAST_DATE" != "$DATE" ]]; then
  LAST_LINE=0
fi

# Ensure daily log file exists
if [[ ! -f "$DAILY_LOG" ]]; then
  cat > "$DAILY_LOG" <<HEADER
# Daily Log - $DATE

Auto-log of #trading-floor decisions and alerts.

HEADER
fi

# If no trading-floor log yet, just update state and exit
if [[ ! -f "$LOG_FILE" ]]; then
  echo "$DATE|$LAST_LINE" > "$STATE_FILE"
  exit 0
fi

TOTAL_LINES=$(wc -l < "$LOG_FILE" | tr -d ' ')
if [[ "$TOTAL_LINES" -le "$LAST_LINE" ]]; then
  echo "$DATE|$TOTAL_LINES" > "$STATE_FILE"
  exit 0
fi

# Extract new lines and append full timeline entries
START_LINE=$((LAST_LINE + 1))
NEW_LINES_FILE=$(mktemp)
tail -n +$START_LINE "$LOG_FILE" > "$NEW_LINES_FILE"

cat "$NEW_LINES_FILE" | \
  jq -r --arg skip "SystemError|Gateway agent failed|Connection error|uv_interface_addresses|truncating in injected context|Read: .* failed:|Exec: .* failed:" '
    def boss: (.author == "SaltyLimeSoda" or .author == "Anderoslav" or .author == "BaconMambo");
    select(.msg | test($skip; "i") | not) |
    "- \(.ts) " + (if boss then "[BOSS] " else "" end) + "\(.author): \(.msg | gsub("\n"; " / "))"
  ' >> "$DAILY_LOG"

# Append full report contents when referenced
REPORT_PATHS=$(cat "$NEW_LINES_FILE" | \
  jq -r '.msg' | \
  grep -oE "${DESK_REPORTS_ROOT}/[^[:space:]]+\\.md" | \
  sort -u || true)

if [[ -n "$REPORT_PATHS" ]]; then
  while IFS= read -r REPORT; do
    [[ -z "$REPORT" ]] && continue
    REPORT_REAL="$REPORT"
    if [[ -f "$REPORT_REAL" ]]; then
      if ! grep -q "^## Report: $REPORT$" "$DAILY_LOG"; then
        {
          echo ""
          echo "## Report: $REPORT"
          echo ""
          cat "$REPORT_REAL"
        } >> "$DAILY_LOG"
      fi
    fi
  done <<< "$REPORT_PATHS"
fi

# Cleanup temp files
rm -f "$NEW_LINES_FILE"

# Update state
echo "$DATE|$TOTAL_LINES" > "$STATE_FILE"
