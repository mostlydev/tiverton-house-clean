#!/bin/bash
# trading-readiness-check.sh - Pre-open operational smoke checks for trading stack.
# Usage: trading-readiness-check.sh [--with-screenshot] [--skip-screenshot] [--send-discord-check]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

WITH_SCREENSHOT=true
SEND_DISCORD_CHECK=false
DISCORD_TARGET="${TRADING_INFRA_CHANNEL_ID:-}"
API_BASE="${TRADING_API_BASE_URL}"
POD_NAME="${POD_NAME:-tiverton-house}"
NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

PASS=0
FAIL=0
WARN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-screenshot)
      WITH_SCREENSHOT=true
      shift
      ;;
    --skip-screenshot)
      WITH_SCREENSHOT=false
      shift
      ;;
    --send-discord-check)
      SEND_DISCORD_CHECK=true
      shift
      ;;
    --discord-target)
      DISCORD_TARGET="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

note_pass() {
  local msg="$1"
  echo "[PASS] $msg"
  PASS=$((PASS + 1))
}

note_fail() {
  local msg="$1"
  echo "[FAIL] $msg"
  FAIL=$((FAIL + 1))
}

note_warn() {
  local msg="$1"
  echo "[WARN] $msg"
  WARN=$((WARN + 1))
}

check_cmd() {
  local label="$1"
  local cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    note_pass "$label"
  else
    note_fail "$label"
  fi
}

pod_container_id() {
  local service="$1"
  local running_id stopped_id

  running_id="$(docker ps -q --filter "label=claw.pod=${POD_NAME}" --filter "label=claw.service=${service}" | head -n 1)"
  if [[ -n "$running_id" ]]; then
    printf '%s\n' "$running_id"
    return 0
  fi

  stopped_id="$(docker ps -aq --filter "label=claw.pod=${POD_NAME}" --filter "label=claw.service=${service}" | head -n 1)"
  if [[ -n "$stopped_id" ]]; then
    printf '%s\n' "$stopped_id"
    return 0
  fi

  return 1
}

check_pod_service() {
  local service="$1"
  local expect_health="${2:-false}"
  local container_id status health

  container_id="$(pod_container_id "$service" 2>/dev/null || true)"
  if [[ -z "$container_id" ]]; then
    note_fail "pod service ${service} present"
    return 1
  fi

  status="$(docker inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null || echo "unknown")"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || echo "unknown")"

  if [[ "$status" != "running" ]]; then
    note_fail "pod service ${service} running"
  elif [[ "$expect_health" == "true" && "$health" != "healthy" ]]; then
    note_fail "pod service ${service} healthy"
  elif [[ "$expect_health" == "true" ]]; then
    note_pass "pod service ${service} healthy"
  else
    note_pass "pod service ${service} running"
  fi

  echo "[INFO] pod service ${service} status=$status health=$health container=$container_id"
}

echo "=== Trading Readiness Check ==="
echo "Time (UTC): $NOW_UTC"
echo ""

# 1) Pod services
if command -v docker >/dev/null 2>&1; then
  check_pod_service "postgres" true
  check_pod_service "redis" true
  check_pod_service "trading-api" true
  check_pod_service "sidekiq" false
  check_pod_service "tiverton" true
else
  note_fail "docker available for pod service checks"
fi

# 2) API health + ledger mode
STATUS_JSON="$(trading_api_curl GET "/api/v1/status" -f 2>/dev/null || true)"
POS_TOTAL="-1"
POS_OPEN="-1"
if [[ -n "$STATUS_JSON" ]]; then
  note_pass "API /api/v1/status responds"

  READ_SOURCE="$(echo "$STATUS_JSON" | jq -r '.ledger_migration.read_source // "unknown"' 2>/dev/null || echo "unknown")"
  if [[ "$READ_SOURCE" == "ledger" || "$READ_SOURCE" == "legacy" ]]; then
    note_pass "status read_source reported"
    echo "[INFO] status read_source=$READ_SOURCE"
  else
    note_fail "status read_source reported (actual: $READ_SOURCE)"
  fi

  POS_TOTAL="$(echo "$STATUS_JSON" | jq -r '.positions.total // -1' 2>/dev/null || echo "-1")"
  POS_OPEN="$(echo "$STATUS_JSON" | jq -r '.positions.open // -1' 2>/dev/null || echo "-1")"
  echo "[INFO] status positions.total=$POS_TOTAL positions.open=$POS_OPEN"
else
  note_fail "API /api/v1/status responds"
fi

LEDGER_STATS="$(trading_api_curl GET "/api/v1/ledger/stats" -f 2>/dev/null || true)"
if [[ -n "$LEDGER_STATS" ]]; then
  note_pass "API /api/v1/ledger/stats responds"
  OPEN_LOTS="$(echo "$LEDGER_STATS" | jq -r '.position_lots.open // -1' 2>/dev/null || echo "-1")"
  if [[ "$OPEN_LOTS" =~ ^[0-9]+$ ]] && (( OPEN_LOTS >= 0 )); then
    note_pass "ledger open lot count available"
    if (( OPEN_LOTS == 0 )); then
      note_warn "ledger currently has no open lots; flat fresh desks are expected to show 0"
    fi
  else
    note_fail "ledger open lot count available"
  fi
  echo "[INFO] ledger position_lots.open=$OPEN_LOTS"

  if [[ "$POS_TOTAL" =~ ^[0-9]+$ ]] && [[ "$OPEN_LOTS" =~ ^[0-9]+$ ]] && (( POS_TOTAL == 0 )) && (( OPEN_LOTS > 0 )); then
    note_warn "status endpoint shows 0 positions while ledger has open lots (known divergence)"
  fi
else
  note_fail "API /api/v1/ledger/stats responds"
fi

# 3) Full ledger workflow integration tests
if "${SCRIPT_DIR}/test-ledger-workflow.sh" >/tmp/test-ledger-workflow.latest.log 2>&1; then
  note_pass "test-ledger-workflow.sh"
else
  note_fail "test-ledger-workflow.sh"
  echo "[INFO] ledger test output (tail):"
  tail -n 30 /tmp/test-ledger-workflow.latest.log || true
fi

# 4) Dashboard screenshot proof
if [[ "$WITH_SCREENSHOT" == "true" ]]; then
  if command -v agent-browser >/dev/null 2>&1; then
    TS="$(date +%Y%m%d-%H%M%S)"
    SHOT_PATH="/tmp/dashboard-readiness-${TS}.png"
    DASHBOARD_URL="$(trading_api_host_url 2>/dev/null || true)"
    if [[ -n "$DASHBOARD_URL" ]]; then
      if agent-browser set viewport 1366 900 >/dev/null 2>&1 \
        && agent-browser open "${DASHBOARD_URL}/" >/dev/null 2>&1 \
        && agent-browser wait 2000 >/dev/null 2>&1 \
        && agent-browser screenshot "$SHOT_PATH" >/dev/null 2>&1; then
        note_pass "dashboard screenshot captured"
        echo "[INFO] screenshot=$SHOT_PATH"
      else
        note_fail "dashboard screenshot captured"
      fi
    else
      DASHBOARD_HTML="$(trading_api_curl GET "/" -f 2>/dev/null || true)"
      if [[ -n "$DASHBOARD_HTML" ]]; then
        note_pass "dashboard root responds (internal)"
        note_warn "dashboard screenshot skipped; trading-api is pod-internal only"
      else
        note_fail "dashboard root responds (internal)"
      fi
    fi
  else
    note_fail "agent-browser installed"
  fi
fi

# 5) Optional Discord outbound smoke check
if [[ "$SEND_DISCORD_CHECK" == "true" ]]; then
  MSG="[ops-check ${NOW_UTC}] readiness smoke test from trading-readiness-check.sh"
  if notify_discord_channel "$DISCORD_TARGET" "$MSG"; then
    note_pass "discord outbound send"
  else
    note_fail "discord outbound send"
  fi
fi

echo ""
echo "=== Summary ==="
echo "PASS=$PASS"
echo "WARN=$WARN"
echo "FAIL=$FAIL"

if (( FAIL > 0 )); then
  exit 1
fi

exit 0
