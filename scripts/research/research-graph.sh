#!/usr/bin/env bash
# research-graph.sh - Convenience wrapper: show full relationship graph for an entity
# Usage: research-graph.sh <entity_id>
exec "$(dirname "$0")/research-entity.sh" graph "$@"
