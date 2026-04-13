#!/bin/bash
# Agent container healthcheck.
# Verifies both picoclaw process health AND Discord gateway connectivity.
# Exits 0 (healthy) or 1 (unhealthy). Writes nothing to disk.
set -euo pipefail

# 1. Check picoclaw HTTP health endpoint
health=$(curl -fsS --max-time 5 http://localhost:18790/health 2>/dev/null) || exit 1
echo "$health" | grep -q '"ok"' || exit 1

# 2. Check Discord gateway is alive via REST API
# GET /users/@me is the lightest authenticated call — no side effects.
if [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
  discord=$(curl -fsS --max-time 5 \
    -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
    https://discord.com/api/v10/users/@me 2>/dev/null) || exit 1
  echo "$discord" | grep -q '"id"' || exit 1
fi

exit 0
