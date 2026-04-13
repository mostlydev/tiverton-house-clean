# Research Scripts

Wrapper scripts for the research knowledge graph API. Used by analyst agents to manage entities, relationships, investigations, and notes.

## Scripts

- **research-entity.sh** -- Create, list, show, update, and graph research entities (companies, people, sectors, themes, regulators).
- **research-graph.sh** -- Convenience alias for `research-entity.sh graph <id>`. Shows full relationship graph for an entity.
- **research-investigation.sh** -- Manage investigations: create, update status, link entities with roles, list linked entities.
- **research-note.sh** -- Attach notes (findings, risk flags, thesis updates, data points, questions) to entities or investigations.
- **research-positions-xref.sh** -- Cross-reference knowledge graph entities against held positions. Shows which positions have research coverage and which do not.

## Pattern

All scripts source `../lib/pod-env.sh` and use `trading_api_curl_with_status` for API calls. Auth headers, base URL, and pod identity are handled automatically. Pass `--help` to any script for usage details.
