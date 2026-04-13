#!/bin/bash
# summarize-trading-floor.sh
# Generates concise summary of recent #trading-floor activity

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

DATE=$(date +%Y-%m-%d)
TIME=$(date +%H:%M)
LOG_FILE="${DESK_LOGS_ROOT}/trading-floor/$DATE.jsonl"
SUMMARY_FILE="${DESK_LOGS_ROOT}/trading-floor-latest.md"
CONTEXT_FILE=/tmp/trading-floor-context.txt

# Check if log exists
if [ ! -f "$LOG_FILE" ]; then
  echo "No trading floor log for today"
  exit 0
fi

# Get last 60 minutes of messages
CUTOFF=$(date -d '60 minutes ago' +%H:%M:%S 2>/dev/null || date -v-60M +%H:%M:%S)

# Extract recent messages
if grep -q "\"ts\"" "$LOG_FILE" 2>/dev/null; then
  grep "\"ts\"" "$LOG_FILE" | \
    jq -r 'select(.ts >= "'$CUTOFF'") | "[\(.ts)] \(.author): \(.msg)"' \
    > "$CONTEXT_FILE" 2>/dev/null || echo "" > "$CONTEXT_FILE"
else
  echo "" > "$CONTEXT_FILE"
fi

# If no recent messages, create empty summary
if [ ! -s "$CONTEXT_FILE" ]; then
  cat > "$SUMMARY_FILE" <<EOF
## Trading Floor Update [$TIME]

No recent activity in the last hour.

---
*Last updated: $TIME | Next update: +15m*

Full log: ${LOG_FILE}
EOF
  exit 0
fi

# Generate summary for Tiverton/trading-floor feed (Discord-only routing)
# Using main agent's session with grok-beta model
cat > /tmp/summarize-system.txt <<'EOF'
You are summarizing #trading-floor conversation for trading agents.

INSTRUCTIONS:
- Extract 3-7 key bullets ONLY
- Focus on: alerts, trade decisions, Boss questions, macro events, coordination needs
- Always mention TICKER SYMBOLS when relevant
- Always mention TRADE DECISIONS (BUY/SELL/APPROVED/DENIED)
- Skip: routine updates, small talk, confirmations
- Format: Brief bullets, no fluff
- Flag urgency with [!] prefix for:
  * Boss questions/decisions/orders
  * Breaking news requiring immediate action
  * Trade conflicts or risk alerts
  * Anything requiring response

OUTPUT FORMAT (markdown):
## Trading Floor Update [$TIME]

- [!] Urgent item (if any) - mention TICKERS
- Key signal/alert - mention TICKERS
- Trade decision - BUY/SELL TICKER $amount
- Boss question (if any)
- Macro event (if any)

Keep it concise. Agents read this every 15 min.
EOF

# Build the prompt with context
PROMPT="Summarize the following #trading-floor messages from the last hour:

$(cat $CONTEXT_FILE)

Current time: $TIME
Remember to mention TICKERS and DECISIONS clearly."

# Build combined prompt with system instructions
COMBINED_PROMPT="$(cat /tmp/summarize-system.txt)

$PROMPT"

# Call agent command to generate summary
# Using a temporary session ID to avoid cluttering main sessions
TEMP_SESSION="summarizer-$(date +%s)"

# Set OpenClaw environment for source build
export OPENCLAW_STATE_DIR="${OPENCLAW_STATE_ROOT}"
export OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH}"

RESPONSE=$(openclaw agent \
  --agent main \
  --session-id "$TEMP_SESSION" \
  --message "$COMBINED_PROMPT" \
  2>&1)

# Extract the summary content (skip metadata lines)
# The response should contain the actual summary
SUMMARY_CONTENT=$(echo "$RESPONSE" | grep -v "^Agent:" | grep -v "^Session:" | grep -v "^Tokens:" | sed '/^$/d' | head -100)

# If empty or looks wrong, use error message
if [ -z "$SUMMARY_CONTENT" ] || ! echo "$SUMMARY_CONTENT" | grep -q "Trading Floor"; then
  SUMMARY_CONTENT="## Trading Floor Update [$TIME]

Error generating summary. Check logs or run manually.

---
*Last updated: $TIME*"
fi

# Write summary to file
cat > "$SUMMARY_FILE" <<EOF
$SUMMARY_CONTENT

---
*Last updated: $TIME | Next update: +15m*

Full log: ${LOG_FILE}
EOF

# Cleanup
rm -f /tmp/summarize-system.txt "$CONTEXT_FILE"

echo "Summary generated: $SUMMARY_FILE"
