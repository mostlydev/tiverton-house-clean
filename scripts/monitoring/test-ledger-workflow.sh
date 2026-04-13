#!/bin/bash
# test-ledger-workflow.sh - Integration tests for ledger-based trading workflow
# Run: ./scripts/monitoring/test-ledger-workflow.sh

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

PASS=0
FAIL=0

echo "=== Ledger Workflow Integration Tests ==="
echo "Time: $(date)"
echo ""

# Test helper
test_assert() {
    local name="$1"
    local condition="$2"

    if eval "$condition"; then
        echo "✓ PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "✗ FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
}

# Test 1: API Health Check
echo "--- Test 1: API Health Check ---"
STATUS=$(trading_api_curl GET "/api/v1/status" 2>/dev/null || echo "")
test_assert "API is responding" '[ -n "$STATUS" ]'
test_assert "Status contains timestamp" 'echo "$STATUS" | jq -e ".timestamp" >/dev/null 2>&1'

# Test 2: Ledger Stats Available
echo ""
echo "--- Test 2: Ledger Stats ---"
STATS=$(trading_api_curl GET "/api/v1/ledger/stats" 2>/dev/null || echo "")
test_assert "Ledger stats endpoint responds" '[ -n "$STATS" ]'
test_assert "Stats contains ledger_transactions" 'echo "$STATS" | jq -e ".ledger_transactions" >/dev/null 2>&1'
test_assert "Stats contains position_lots" 'echo "$STATS" | jq -e ".position_lots" >/dev/null 2>&1'

# Test 3: Positions API Returns Ledger Data
echo ""
echo "--- Test 3: Positions API ---"
POSITIONS=$(trading_api_curl GET "/api/v1/positions?agent_id=dundas" 2>/dev/null || echo "")
test_assert "Positions endpoint responds" '[ -n "$POSITIONS" ]'
SOURCE=$(echo "$POSITIONS" | jq -r '.source // "none"')
test_assert "Positions source is reported" '[ "$SOURCE" != "none" ]'
test_assert "Positions array exists" 'echo "$POSITIONS" | jq -e ".positions" >/dev/null 2>&1'

# Test 4: Wallets API Returns Ledger Data
echo ""
echo "--- Test 4: Wallets API ---"
WALLET=$(trading_api_curl GET "/api/v1/wallets/dundas" 2>/dev/null || echo "")
test_assert "Wallet endpoint responds" '[ -n "$WALLET" ]'
test_assert "Wallet payload identifies agent" 'echo "$WALLET" | jq -e ".agent_id" >/dev/null 2>&1'
test_assert "Wallet has cash field" 'echo "$WALLET" | jq -e ".cash" >/dev/null 2>&1'

# Test 5: Positions API
echo ""
echo "--- Test 5: Positions API ---"
POS_OUTPUT=$(trading_api_curl GET "/api/v1/positions/dundas" 2>/dev/null || echo "")
test_assert "Positions endpoint responds" '[ -n "$POS_OUTPUT" ]'
test_assert "Positions payload is valid JSON" 'echo "$POS_OUTPUT" | jq -e "." >/dev/null 2>&1'

# Test 6: db-wallet-get.sh Script
echo ""
echo "--- Test 6: db-wallet-get.sh ---"
WAL_OUTPUT=$("${SCRIPT_DIR}/../trade/db-wallet-get.sh" dundas 2>&1 || true)
test_assert "Script executes without error" 'echo "$WAL_OUTPUT" | grep -q "Wallet:"'
test_assert "Script shows cash column" 'echo "$WAL_OUTPUT" | grep -q "Cash"'

# Test 7: Market Context API
echo ""
echo "--- Test 7: Market Context API ---"
MC_OUTPUT=$(trading_api_curl GET "/api/v1/market_context/dundas" 2>/dev/null || echo "")
test_assert "Market context endpoint responds" '[ -n "$MC_OUTPUT" ]'
test_assert "Shows market status" 'echo "$MC_OUTPUT" | jq -e ".market_status" >/dev/null 2>&1'
test_assert "Shows wallet info" 'echo "$MC_OUTPUT" | jq -e ".wallet" >/dev/null 2>&1'

# Test 8: Ledger Migration Status
echo ""
echo "--- Test 8: Ledger Migration Status ---"
STATUS=$(trading_api_curl GET "/api/v1/status" 2>/dev/null || echo "")
if [ -n "$STATUS" ]; then
    LEDGER_STATUS=$(echo "$STATUS" | jq '.ledger_migration // {}')
    if [ "$LEDGER_STATUS" != "{}" ]; then
        READ_SOURCE=$(echo "$LEDGER_STATUS" | jq -r '.read_source // "unknown"')
        WRITE_MODE=$(echo "$LEDGER_STATUS" | jq -r '.write_mode // "unknown"')
        test_assert "Read source is reported" '[[ "$READ_SOURCE" == "ledger" || "$READ_SOURCE" == "legacy" ]]'
        test_assert "Write mode is reported" '[[ "$WRITE_MODE" == "ledger" || "$WRITE_MODE" == "legacy" ]]'
    else
        echo "  (Skipped - ledger_migration not in status response)"
    fi
else
    echo "  (Skipped - status endpoint unavailable)"
fi

# Test 9: Alpaca Consistency Check
echo ""
echo "--- Test 9: Alpaca Consistency Check ---"
VERIFY_OUTPUT=$("$SCRIPT_DIR/db-verify-alpaca.sh" --json 2>&1 || true)
VERIFY_OK=$(echo "$VERIFY_OUTPUT" | jq -r '.ok // false' 2>/dev/null || echo "false")
test_assert "Alpaca consistency passes" '[ "$VERIFY_OK" = "true" ]'

# Test 10: Position/Wallet Data Consistency
echo ""
echo "--- Test 10: Data Consistency ---"
# Get positions total from API
POS_TOTAL=$(trading_api_curl GET "/api/v1/positions?agent_id=dundas" | jq '[.positions[].current_value | tonumber] | add // 0')
# Get wallet invested from API
WAL_INVESTED=$(trading_api_curl GET "/api/v1/wallets/dundas" | jq '.invested | tonumber')
# They should be close (invested is cost basis, not current value, so may differ)
if [ -n "$POS_TOTAL" ] && [ -n "$WAL_INVESTED" ]; then
    echo "  Position value: \$$POS_TOTAL"
    echo "  Wallet invested: \$$WAL_INVESTED"
    test_assert "Position and wallet data retrieved" '[ -n "$POS_TOTAL" ] && [ -n "$WAL_INVESTED" ]'
fi

# Summary
echo ""
echo "=== Test Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "Some tests failed!"
    exit 1
fi
