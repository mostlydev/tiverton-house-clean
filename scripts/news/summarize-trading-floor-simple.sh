#!/bin/bash
# summarize-trading-floor-simple.sh
# Quick summary without agent call - just extracts key messages

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

DATE=$(date +%Y-%m-%d)
TIME=$(date +%H:%M)
LOG_FILE="${DESK_LOGS_ROOT}/trading-floor/$DATE.jsonl"
SUMMARY_FILE="${DESK_LOGS_ROOT}/trading-floor-latest.md"

# Check if log exists
if [ ! -f "$LOG_FILE" ]; then
  cat > "$SUMMARY_FILE" <<EOF
## Trading Floor Update [$TIME]

No trading floor log for today.

---
*Last updated: $TIME | Next update: +15m*
EOF
  exit 0
fi

# Get last 60 minutes of messages
CUTOFF=$(date -d '60 minutes ago' +%H:%M:%S 2>/dev/null || date -v-60M +%H:%M:%S)

# Extract recent messages and format
RECENT=$(grep "\"ts\"" "$LOG_FILE" 2>/dev/null | \
  jq -r 'select(.ts >= "'$CUTOFF'") | "[\(.ts)] \(.author): \(.msg)"' 2>/dev/null || echo "")

if [ -z "$RECENT" ]; then
  cat > "$SUMMARY_FILE" <<EOF
## Trading Floor Update [$TIME]

No recent activity in the last hour.

---
*Last updated: $TIME | Next update: +15m*

Full log: ${LOG_FILE}
EOF
  exit 0
fi

# Simple extraction of key patterns
BULLETS=""

# Look for Boss messages
if echo "$RECENT" | grep -qi "SaltyLimeSoda"; then
  BOSS_MSG=$(echo "$RECENT" | grep "SaltyLimeSoda" | tail -1 | sed 's/^\[.*\] SaltyLimeSoda: //')
  BULLETS="${BULLETS}- [!] **Boss:** $BOSS_MSG\n"
fi

# Look for trade decisions (PROPOSED, APPROVED, FILLED, FAILED)
while IFS= read -r line; do
  if echo "$line" | grep -qE "\[PROPOSED\]|\[APPROVED\]|\[FILLED\]|\[FAILED\]|\[DENIED\]"; then
    MSG=$(echo "$line" | sed 's/^\[.*\] [^:]*: //' | head -1)
    BULLETS="${BULLETS}- $MSG\n"
  fi
done <<< "$RECENT"

# Look for critical/urgent markers
if echo "$RECENT" | grep -qi "CRITICAL\|URGENT\|!\]"; then
  CRITICAL=$(echo "$RECENT" | grep -i "CRITICAL\|URGENT\|!\]" | tail -2 | sed 's/^\[.*\] [^:]*: //' | sed 's/^/- /')
  BULLETS="${BULLETS}$CRITICAL\n"
fi

# Look for research directives
if echo "$RECENT" | grep -qi "RESEARCH"; then
  RESEARCH=$(echo "$RECENT" | grep -i "RESEARCH" | tail -1 | sed 's/^\[.*\] [^:]*: //' | head -1)
  BULLETS="${BULLETS}- $RESEARCH\n"
fi

# If no bullets extracted, show message count
if [ -z "$BULLETS" ]; then
  MSG_COUNT=$(echo "$RECENT" | wc -l)
  BULLETS="- $MSG_COUNT messages in last hour (no high-priority items detected)"
fi

# Write summary
cat > "$SUMMARY_FILE" <<EOF
## Trading Floor Update [$TIME]

$(echo -e "$BULLETS")

---
*Last updated: $TIME | Next update: +15m*

Full log: ${LOG_FILE}
EOF

echo "Summary generated: $SUMMARY_FILE"
