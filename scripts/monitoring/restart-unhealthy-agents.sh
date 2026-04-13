#!/bin/bash
# Restart any agent containers marked unhealthy by Docker.
# Intended to run from host crontab every 2-3 minutes.
# Writes nothing to disk; only restarts containers with health=unhealthy.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

AGENTS="tiverton weston logan gerrard dundas"
COMPOSE="docker compose -f compose.generated.yml"

for agent in $AGENTS; do
  health=$($COMPOSE ps --format '{{.Health}}' "$agent" 2>/dev/null || true)
  if [ "$health" = "unhealthy" ]; then
    logger -t pod-watchdog "Restarting unhealthy agent: $agent"
    $COMPOSE restart "$agent" 2>/dev/null
  fi
done
