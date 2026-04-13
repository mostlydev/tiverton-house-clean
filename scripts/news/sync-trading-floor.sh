#!/bin/bash
# sync-trading-floor.sh
# Fetches #trading-floor messages via Discord API and appends to daily JSONL log
# Rewritten 2026-01-26 to bypass hanging openclaw CLI

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

LOCK_FILE="${DESK_LOGS_ROOT}/trading-floor/.sync-lock"
LOOP_COUNT="${LOOP_COUNT:-1}"
INTERVAL_SEC="${INTERVAL_SEC:-0}"

run_once() {

DATE=$(date +%Y-%m-%d)
LOG_DIR="${DESK_LOGS_ROOT}/trading-floor"
LOG_FILE="$LOG_DIR/$DATE.jsonl"
STATE_FILE="$LOG_DIR/.last-message-id"
CHANNEL_ID="${TRADING_FLOOR_CHANNEL_ID:-}"

# Discord bot token (Tiverton)
DISCORD_TOKEN="${TRADING_FLOOR_BOT_TOKEN:-${TIVERTON_BOT_TOKEN:-${DISCORD_BOT_TOKEN:-}}}"

if [[ -z "$CHANNEL_ID" || -z "$DISCORD_TOKEN" ]]; then
  echo "ERROR: TRADING_FLOOR_CHANNEL_ID and TRADING_FLOOR_BOT_TOKEN/TIVERTON_BOT_TOKEN are required" >&2
  exit 1
fi

# Create log directory if needed
mkdir -p "$LOG_DIR"

# Get last processed message ID (or empty for first run)
LAST_ID=$(cat "$STATE_FILE" 2>/dev/null || echo "")

# Build API URL - use 'after' param if we have a last ID
if [ -n "$LAST_ID" ]; then
  API_URL="https://discord.com/api/v10/channels/${CHANNEL_ID}/messages?limit=100&after=${LAST_ID}"
else
  API_URL="https://discord.com/api/v10/channels/${CHANNEL_ID}/messages?limit=100"
fi

# Fetch messages from Discord API (with 10s timeout)
MESSAGES_JSON=$(curl -s --max-time 10 \
  -H "Authorization: Bot ${DISCORD_TOKEN}" \
  -H "Content-Type: application/json" \
  "$API_URL" 2>/dev/null || echo "[]")

# Check if we got valid JSON array
if ! echo "$MESSAGES_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "ERROR: Failed to fetch messages or invalid JSON: $MESSAGES_JSON"
  exit 1
fi

# Check if array is empty
MSG_COUNT=$(echo "$MESSAGES_JSON" | jq 'length')
if [ "$MSG_COUNT" -eq 0 ]; then
  # Touch last-run file so staleness checks know we ran successfully
  touch "$LOG_DIR/.last-run"

  # Keep summaries/feed fresh even when no new messages arrive
  "${SCRIPT_DIR}/summarize-trading-floor-simple.sh"
  if [[ -x "${SCRIPT_DIR}/generate-trading-floor-feed.sh" ]]; then
    "${SCRIPT_DIR}/generate-trading-floor-feed.sh" || true
  fi
  if [[ -x "${SCRIPT_DIR}/daily-log-update.sh" ]]; then
    "${SCRIPT_DIR}/daily-log-update.sh" || true
  fi

  echo "No new messages"
  exit 0
fi

# Discord returns newest first, so reverse for chronological order
# Extract: id, timestamp, author username, content
NEW_MESSAGES=$(echo "$MESSAGES_JSON" | jq -c --arg channel_id "$CHANNEL_ID" '
  reverse | .[] | {
    id: .id,
    ts_iso: (.timestamp | split(".")[0] | split("+")[0]),
    ts: (.timestamp | split(".")[0] | split("+")[0] | strptime("%Y-%m-%dT%H:%M:%S") | strftime("%H:%M:%S")),
    channel_id: $channel_id,
    author: (.author.global_name // .author.username // "unknown"),
    msg: (.content // "")
  }
')

# Append new messages to log
echo "$NEW_MESSAGES" | while IFS= read -r line; do
  echo "$line" >> "$LOG_FILE"
done

# Update state with latest message ID (last line = newest after reverse)
NEW_LAST_ID=$(echo "$NEW_MESSAGES" | tail -1 | jq -r '.id')
if [ -n "$NEW_LAST_ID" ] && [ "$NEW_LAST_ID" != "null" ]; then
  echo "$NEW_LAST_ID" > "$STATE_FILE"
fi

# Trigger summarizer (using simple version - LLM version times out with new gateway)
"${SCRIPT_DIR}/summarize-trading-floor-simple.sh"

# Update rolling feed (last 4 days)
if [[ -x "${SCRIPT_DIR}/generate-trading-floor-feed.sh" ]]; then
  "${SCRIPT_DIR}/generate-trading-floor-feed.sh" || true
fi

# Update daily action log (best-effort)
if [[ -x "${SCRIPT_DIR}/daily-log-update.sh" ]]; then
  "${SCRIPT_DIR}/daily-log-update.sh" || true
fi

echo "Synced $MSG_COUNT new messages"
}

(
  flock -n 9 || exit 0

  i=1
  while [ "$i" -le "$LOOP_COUNT" ]; do
    run_once
    if [ "$i" -lt "$LOOP_COUNT" ] && [ "$INTERVAL_SEC" -gt 0 ]; then
      sleep "$INTERVAL_SEC"
    fi
    i=$((i + 1))
  done
) 9>"$LOCK_FILE"
